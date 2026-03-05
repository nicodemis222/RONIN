import asyncio
import logging

import numpy as np
from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from app.config import settings
from app.schemas.transcript import TranscriptSegment

router = APIRouter()
logger = logging.getLogger(__name__)


@router.websocket("/ws/audio")
async def audio_websocket(websocket: WebSocket):
    logger.info("WebSocket connection request received")
    await websocket.accept()
    logger.info("WebSocket accepted")

    app = websocket.app
    transcription = app.state.transcription
    llm = app.state.llm
    meeting = app.state.meeting

    session = meeting.get_active_session()
    if not session:
        logger.warning("No active meeting session — closing WebSocket with code 4000")
        await websocket.close(code=4000, reason="No active meeting session")
        return

    logger.info(f"Active session found: {session.session_id}")

    last_llm_call = 0.0
    chunks_received = 0
    copilot_task: asyncio.Task | None = None  # Track the single in-flight call

    try:
        while True:
            data = await websocket.receive_bytes()
            chunks_received += 1
            audio_chunk = np.frombuffer(data, dtype=np.int16)
            transcription.add_audio(audio_chunk)

            if chunks_received <= 3 or chunks_received % 50 == 0:
                buf_duration = len(transcription.audio_buffer) / 16000
                logger.info(
                    f"Audio chunk #{chunks_received}: {len(data)} bytes, "
                    f"buffer={buf_duration:.1f}s, "
                    f"energy={np.abs(audio_chunk).mean():.0f}"
                )

            try:
                transcript_result = await transcription.try_transcribe()
            except Exception as e:
                logger.error(f"Transcription error: {e}", exc_info=True)
                await websocket.send_json(
                    {"type": "error", "data": {"message": f"Transcription error: {e}"}}
                )
                continue

            if transcript_result:
                logger.info(f"Transcript delta: '{transcript_result['text']}'")
                segment = TranscriptSegment(
                    text=transcript_result["text"],
                    full_text=transcript_result["full_text"],
                    timestamp=transcript_result["timestamp"],
                )

                await websocket.send_json(
                    {"type": "transcript_update", "data": segment.model_dump()}
                )
                logger.info("Sent transcript_update to client")

                session.append_transcript(segment)

                # Only trigger a new copilot call if:
                #  1. Debounce has elapsed
                #  2. No copilot call is currently in-flight
                # This prevents piling up slow LLM calls that compete for GPU
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
        transcription.reset_buffer()
    except Exception as e:
        logger.error(
            f"WebSocket handler error after {chunks_received} chunks: {e}",
            exc_info=True,
        )
        transcription.reset_buffer()


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
    except Exception as e:
        logger.error(f"Copilot generation failed: {e}", exc_info=True)
        try:
            await websocket.send_json({"type": "error", "data": {"message": str(e)}})
        except RuntimeError:
            logger.info("Could not send error to client — WebSocket already closed")
