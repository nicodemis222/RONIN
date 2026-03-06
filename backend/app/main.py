import logging
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

    # Print the auth token so the Swift app can read it from stdout.
    # This is the ONLY way the token is communicated — never logged or written to disk.
    print(f"RONIN_AUTH_TOKEN={settings.auth_token}", flush=True)
    print(f"RONIN_LLM_PROVIDER={settings.llm_provider}", flush=True)
    logger.info("Auth token and provider info printed to stdout")

    yield
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
