import asyncio
import logging

import numpy as np
from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from app.config import settings
from app.schemas.transcript import TranscriptSegment

router = APIRouter()
logger = logging.getLogger(__name__)

# Track active WebSocket connections to enforce the limit
_active_ws_count = 0


def _verify_ws_token(websocket: WebSocket) -> bool:
    """Verify the auth token on WebSocket connections via query parameter."""
    token = websocket.query_params.get("token", "")
    return token == settings.auth_token


@router.websocket("/ws/audio")
async def audio_websocket(websocket: WebSocket):
    global _active_ws_count

    logger.info("WebSocket connection request received")

    # ── Auth check ──────────────────────────────────────────────────
    if not _verify_ws_token(websocket):
        logger.warning("WebSocket rejected — invalid auth token")
        await websocket.close(code=4001, reason="Unauthorized")
        return

    # ── Connection limit ────────────────────────────────────────────
    if _active_ws_count >= settings.ws_max_connections:
        logger.warning("WebSocket rejected — max connections reached")
        await websocket.close(code=4002, reason="Max connections reached")
        return

    await websocket.accept()
    _active_ws_count += 1
    logger.info(f"WebSocket accepted (active: {_active_ws_count})")

    app = websocket.app
    transcription = app.state.transcription
    llm = app.state.llm
    meeting = app.state.meeting

    session = meeting.get_active_session()
    if not session:
        logger.warning("No active meeting session — closing WebSocket with code 4000")
        await websocket.close(code=4000, reason="No active meeting session")
        _active_ws_count -= 1
        return

    logger.info(f"Active session found: {session.session_id}")

    last_llm_call = 0.0
    chunks_received = 0
    copilot_task: asyncio.Task | None = None  # Track the single in-flight call

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
                #  1. Debounce has elapsed
                #  2. No copilot call is currently in-flight
                now = asyncio.get_event_loop().time()
                in_flight = copilot_task is not None and not copilot_task.done()

                if now - last_llm_call >= settings.llm_debounce_seconds and not in_flight:
                    last_llm_call = now
                    logger.info("Triggering copilot LLM call")
                    copilot_task = asyncio.create_task(
                        _generate_and_send_copilot(websocket, llm, session)
                    )
                elif in_flight:
                    logger.debug("Skipping copilot — previous call still in-flight")

    except WebSocketDisconnect:
        logger.info(f"WebSocket disconnected after {chunks_received} chunks")
        if copilot_task and not copilot_task.done():
            copilot_task.cancel()
            logger.info("Cancelled in-flight copilot task on disconnect")
        transcription.reset_buffer()
    except Exception as e:
        logger.error(f"WebSocket handler error after {chunks_received} chunks: {e}", exc_info=True)
        if copilot_task and not copilot_task.done():
            copilot_task.cancel()
        transcription.reset_buffer()
    finally:
        _active_ws_count -= 1
        logger.info(f"WebSocket closed (active: {_active_ws_count})")


async def _generate_and_send_copilot(websocket: WebSocket, llm, session):
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
        logger.error(f"Copilot generation failed: {e}", exc_info=True)
        try:
            await websocket.send_json(
                {"type": "error", "data": {"message": "Copilot generation failed — check backend logs"}}
            )
        except RuntimeError:
            logger.info("Could not send error to client — WebSocket already closed")
