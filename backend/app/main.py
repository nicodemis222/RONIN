import logging
import os
import sys
import tempfile
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException, Request
from starlette.websockets import WebSocket

from app.routers import meeting, ws
from app.routers.ws import reset_connections
from app.services.llm_client import LLMClient
from app.services.meeting_state import MeetingStateManager
from app.services.transcription import TranscriptionService
from app.services.provider_factory import create_provider
from app.config import settings

# Path where auth token is written as a fallback when stdout pipe breaks.
# The Swift app reads from stdout first, then falls back to this file.
_AUTH_TOKEN_FILE = os.path.join(tempfile.gettempdir(), "ronin_auth_token")

logger = logging.getLogger(__name__)


# ── Security: Auth token verification ─────────────────────────────────

async def verify_auth_token(request: Request):
    """Verify the Bearer token on all HTTP endpoints.

    The token is generated at startup and printed to stdout so the Swift app
    can read it. This prevents other localhost processes or malicious browser
    scripts from accessing meeting data.
    """
    if request.url.path == "/meeting/health":
        return  # Health check is unauthenticated for monitoring

    auth = request.headers.get("Authorization", "")
    if auth != f"Bearer {settings.auth_token}":
        raise HTTPException(status_code=401, detail="Unauthorized")


def verify_ws_auth_token(websocket: WebSocket) -> bool:
    """Verify the auth token on WebSocket connections via query parameter."""
    token = websocket.query_params.get("token", "")
    return token == settings.auth_token


# ── Auth token delivery ───────────────────────────────────────────────

def _deliver_auth_token(token: str, provider: str):
    """Send the auth token to the Swift app via stdout, with file fallback.

    The stdout pipe can break during rapid restarts or in bundled (DMG) mode,
    causing a BrokenPipeError that would crash the entire lifespan if unhandled.
    We write to a temp file as a fallback so the Swift app can always retrieve it.
    """
    # Always write fallback file first (most reliable)
    try:
        with open(_AUTH_TOKEN_FILE, "w") as f:
            f.write(token)
        os.chmod(_AUTH_TOKEN_FILE, 0o600)  # Owner-only read/write
    except Exception as e:
        logger.warning(f"Could not write auth token file: {e}")

    # Try stdout pipe (primary channel)
    try:
        print(f"RONIN_AUTH_TOKEN={token}", flush=True)
        print(f"RONIN_LLM_PROVIDER={provider}", flush=True)
        logger.info("Auth token and provider info printed to stdout")
    except (BrokenPipeError, OSError) as e:
        logger.warning(f"stdout pipe broken ({e}) — token written to {_AUTH_TOKEN_FILE}")
        # Try stderr as secondary channel (Swift pipes both to the same handle)
        try:
            sys.stderr.write(f"RONIN_AUTH_TOKEN={token}\n")
            sys.stderr.write(f"RONIN_LLM_PROVIDER={provider}\n")
            sys.stderr.flush()
        except (BrokenPipeError, OSError):
            pass  # File fallback is still available


# ── Application lifecycle ──────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Clear any stale connection tracking from a previous lifecycle
    reset_connections()

    app.state.transcription = TranscriptionService(model_name=settings.whisper_model)
    app.state.meeting = MeetingStateManager()

    # Create the LLM provider (or None for transcription-only mode)
    provider = create_provider()
    if provider:
        app.state.llm = LLMClient(provider=provider)
        # Auto-detect the loaded model's context length and calibrate budgets.
        try:
            n_ctx = await app.state.llm.detect_context_length()
            logger.info(f"LLM ready — context: {n_ctx:,} tokens")
        except Exception as e:
            logger.warning(f"Context detection failed: {e} — using default budgets")
    else:
        app.state.llm = None
        logger.info("LLM provider: none — transcription-only mode")

    # Communicate auth token to the Swift app via stdout pipe.
    # Also write to a temp file as a fallback — the stdout pipe can break
    # during rapid restarts or in bundled mode (BrokenPipeError).
    _deliver_auth_token(settings.auth_token, settings.llm_provider)

    yield

    # ── Shutdown: clean up auth token file ────────────────────────
    try:
        os.unlink(_AUTH_TOKEN_FILE)
    except FileNotFoundError:
        pass

    # ── Shutdown: save active transcript as safety net ─────────────
    active = app.state.meeting.get_active_session()
    if active and active.transcript_segments:
        from app.routers.meeting import _save_transcript
        logger.info(
            f"Saving active transcript on shutdown "
            f"({len(active.transcript_segments)} segments)"
        )
        _save_transcript(active)
        app.state.meeting.end_session(active.session_id)

    app.state.transcription.cleanup()
    if app.state.llm:
        await app.state.llm.close()


app = FastAPI(title="Ronin Backend", lifespan=lifespan)

# No CORS middleware — the Swift app uses URLSession (not browser fetch),
# so CORS is unnecessary. Removing it prevents browser-based cross-origin
# attacks that could exfiltrate meeting transcripts.

app.include_router(
    meeting.router,
    prefix="/meeting",
    tags=["meeting"],
    dependencies=[Depends(verify_auth_token)],
)
app.include_router(ws.router, tags=["websocket"])
