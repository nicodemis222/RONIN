import asyncio
import logging
import uuid

import numpy as np
from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from app.config import settings
from app.schemas.transcript import TranscriptSegment

router = APIRouter()
logger = logging.getLogger(__name__)

# Track active WebSocket connections by ID (robust, never drifts)
_active_connections: set[str] = set()

# Maximum cooldown after repeated rate-limit failures (2 minutes)
_MAX_COOLDOWN = 120.0


def _verify_ws_token(websocket: WebSocket) -> bool:
    """Verify the auth token on WebSocket connections via query parameter."""
    token = websocket.query_params.get("token", "")
    return token == settings.auth_token


def get_active_ws_count() -> int:
    """Return current number of active WebSocket connections (for testing)."""
    return len(_active_connections)


def reset_connections() -> None:
    """Force-clear all tracked connections (called on backend startup)."""
    _active_connections.clear()
    logger.info("WebSocket connection tracker reset")


@router.websocket("/ws/audio")
async def audio_websocket(websocket: WebSocket):
    conn_id = uuid.uuid4().hex[:8]

    logger.info(f"WebSocket connection request received (conn={conn_id})")

    # ── Auth check ──────────────────────────────────────────────────
    if not _verify_ws_token(websocket):
        logger.warning(f"WebSocket rejected — invalid auth token (conn={conn_id})")
        await websocket.close(code=4001, reason="Unauthorized")
        return

    # ── Connection limit ────────────────────────────────────────────
    if len(_active_connections) >= settings.ws_max_connections:
        logger.warning(
            f"WebSocket rejected — max connections reached "
            f"({len(_active_connections)}/{settings.ws_max_connections}, "
            f"active={_active_connections}) (conn={conn_id})"
        )
        await websocket.close(code=4002, reason="Max connections reached")
        return

    await websocket.accept()
    _active_connections.add(conn_id)
    logger.info(f"WebSocket accepted (active: {len(_active_connections)}, conn={conn_id})")

    app = websocket.app
    transcription = app.state.transcription
    llm = app.state.llm
    meeting = app.state.meeting

    session = meeting.get_active_session()
    if not session:
        logger.warning(f"No active meeting session — closing WebSocket (conn={conn_id})")
        await websocket.close(code=4000, reason="No active meeting session")
        _active_connections.discard(conn_id)
        return

    logger.info(f"Active session found: {session.session_id} (conn={conn_id})")

    last_llm_call = 0.0
    chunks_received = 0
    copilot_task: asyncio.Task | None = None  # Track the single in-flight call

    # Dynamic cooldown: backs off after rate-limit errors, resets on success
    effective_debounce = settings.llm_debounce_seconds
    consecutive_failures = 0

    # Shared state for copilot task to report rate-limit back to main loop.
    # Using a list as a simple mutable container (safe: single-threaded asyncio).
    rate_limit_flag: list[bool] = [False]

    try:
        while True:
            data = await websocket.receive_bytes()
            chunks_received += 1

            # ── Message size check ──────────────────────────────────
            if len(data) > settings.ws_max_message_bytes:
                logger.warning(
                    f"Oversized message rejected: {len(data)} bytes "
                    f"(max {settings.ws_max_message_bytes})"
                )
                continue

            # ── Audio data validation ───────────────────────────────
            if len(data) % 2 != 0:
                logger.warning(f"Odd-length audio data ({len(data)} bytes) — skipping")
                continue

            audio_chunk = np.frombuffer(data, dtype=np.int16)
            transcription.add_audio(audio_chunk)

            if chunks_received <= 3 or chunks_received % 50 == 0:
                buf_duration = len(transcription.audio_buffer) / 16000
                logger.info(
                    f"Audio chunk #{chunks_received}: {len(data)} bytes, "
                    f"buffer={buf_duration:.1f}s"
                )

            try:
                transcript_result = await transcription.try_transcribe()
            except Exception as e:
                logger.error(f"Transcription error: {e}", exc_info=True)
                await websocket.send_json(
                    {"type": "error", "data": {"message": "Transcription error — check backend logs"}}
                )
                continue

            if transcript_result:
                speaker = transcript_result.get("speaker", "")
                # Log segment length, not content (H6: avoid logging PII)
                logger.info(
                    f"Transcript segment: {len(transcript_result['text'])} chars [{speaker}]"
                )
                segment = TranscriptSegment(
                    text=transcript_result["text"],
                    full_text=transcript_result["full_text"],
                    timestamp=transcript_result["timestamp"],
                    speaker=speaker,
                )

                await websocket.send_json(
                    {"type": "transcript_update", "data": segment.model_dump()}
                )

                session.append_transcript(segment)

                # Only trigger a new copilot call if:
                #  1. LLM is configured (not transcription-only mode)
                #  2. Debounce has elapsed (dynamic — increases after rate limits)
                #  3. No copilot call is currently in-flight
                if llm is not None:
                    now = asyncio.get_event_loop().time()
                    in_flight = copilot_task is not None and not copilot_task.done()

                    # ── Adapt debounce based on previous copilot result ──
                    if copilot_task is not None and copilot_task.done():
                        if rate_limit_flag[0]:
                            # Rate limit hit — double the debounce (exponential backoff)
                            consecutive_failures += 1
                            effective_debounce = min(
                                settings.llm_debounce_seconds * (2 ** consecutive_failures),
                                _MAX_COOLDOWN,
                            )
                            logger.warning(
                                f"Rate limit — debounce increased to "
                                f"{effective_debounce:.0f}s "
                                f"(failure #{consecutive_failures})"
                            )
                            rate_limit_flag[0] = False
                        elif consecutive_failures > 0:
                            # Previous call succeeded — restore normal debounce
                            consecutive_failures = 0
                            effective_debounce = settings.llm_debounce_seconds
                            logger.info(
                                f"Copilot succeeded — debounce restored to "
                                f"{effective_debounce:.0f}s"
                            )

                    if now - last_llm_call >= effective_debounce and not in_flight:
                        last_llm_call = now
                        if effective_debounce > settings.llm_debounce_seconds:
                            logger.info(
                                f"Triggering copilot LLM call "
                                f"(cooldown={effective_debounce:.0f}s)"
                            )
                        else:
                            logger.info("Triggering copilot LLM call")
                        copilot_task = asyncio.create_task(
                            _generate_and_send_copilot(
                                websocket, llm, session, rate_limit_flag
                            )
                        )
                    elif in_flight:
                        logger.debug("Skipping copilot — previous call still in-flight")

    except WebSocketDisconnect:
        logger.info(f"WebSocket disconnected after {chunks_received} chunks (conn={conn_id})")
        if copilot_task and not copilot_task.done():
            copilot_task.cancel()
            logger.info(f"Cancelled in-flight copilot task on disconnect (conn={conn_id})")
        transcription.reset_buffer()
    except Exception as e:
        logger.error(f"WebSocket handler error after {chunks_received} chunks: {e} (conn={conn_id})", exc_info=True)
        if copilot_task and not copilot_task.done():
            copilot_task.cancel()
        transcription.reset_buffer()
    finally:
        _active_connections.discard(conn_id)
        logger.info(f"WebSocket closed (active: {len(_active_connections)}, conn={conn_id})")


async def _generate_and_send_copilot(
    websocket: WebSocket,
    llm,
    session,
    rate_limit_flag: list[bool] | None = None,
):
    try:
        recent_1min = session.get_recent_transcript(minutes=1)
        relevant_notes = session.notes_manager.get_relevant(recent_1min)

        logger.info("Calling LLM for copilot response...")
        response = await llm.generate_copilot_response(
            transcript_window=session.get_recent_transcript(
                minutes=settings.transcript_window_minutes
            ),
            config=session.config,
            relevant_notes=relevant_notes,
        )
        try:
            await websocket.send_json(
                {"type": "copilot_response", "data": response.model_dump()}
            )
            logger.info(
                f"Sent copilot_response: {len(response.suggestions)} suggestions, "
                f"{len(response.follow_up_questions)} questions"
            )
        except RuntimeError:
            logger.info("Copilot response ready but WebSocket already closed — skipping send")
    except asyncio.CancelledError:
        logger.info("Copilot task cancelled (meeting ended) — freeing GPU")
    except Exception as e:
        # Surface a user-friendly error message to the client
        error_msg = str(e)
        is_rate_limit = "429" in error_msg or "rate limit" in error_msg.lower()

        if is_rate_limit:
            user_msg = "LLM rate limit reached — suggestions paused temporarily"
            # Signal to main loop to increase debounce
            if rate_limit_flag is not None:
                rate_limit_flag[0] = True
        elif "context" in error_msg.lower() or "n_ctx" in error_msg.lower():
            user_msg = "Transcript too long for model context — increase n_ctx in LLM settings"
        else:
            user_msg = f"Copilot error: {error_msg}"
        logger.error(f"Copilot generation failed: {e}", exc_info=True)
        try:
            await websocket.send_json(
                {"type": "error", "data": {"message": user_msg}}
            )
        except RuntimeError:
            logger.info("Could not send error to client — WebSocket already closed")
