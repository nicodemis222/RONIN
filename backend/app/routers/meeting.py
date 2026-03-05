import logging
import os
import re
from datetime import datetime
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request

from app.schemas.meeting import MeetingSetupRequest, MeetingSetupResponse
from app.schemas.summary import MeetingSummary

router = APIRouter()
logger = logging.getLogger(__name__)

# Transcript persistence directory
TRANSCRIPT_DIR = Path.home() / "Library" / "Logs" / "Ronin" / "transcripts"


def _save_transcript(session) -> Path | None:
    """Persist the full transcript to disk so it's never lost.

    Security: sanitizes filename, restricts directory/file permissions.
    """
    try:
        # Create directory with owner-only permissions (H2)
        TRANSCRIPT_DIR.mkdir(parents=True, exist_ok=True)
        os.chmod(TRANSCRIPT_DIR, 0o700)

        timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        # Sanitize title — strip everything except alphanumeric, hyphen, underscore (H3)
        title_slug = re.sub(r"[^a-zA-Z0-9_-]", "", session.config.title.replace(" ", "-"))[:40]
        filename = f"{timestamp}_{title_slug}_{session.session_id}.txt"
        path = TRANSCRIPT_DIR / filename

        path.write_text(session.full_transcript, encoding="utf-8")
        # Owner-only read/write (H2)
        os.chmod(path, 0o600)

        logger.info(f"Transcript saved ({len(session.transcript_segments)} segments)")
        return path
    except Exception as e:
        logger.error(f"Failed to save transcript: {e}")
        return None


@router.post("/setup", response_model=MeetingSetupResponse)
async def setup_meeting(request: Request, config: MeetingSetupRequest):
    state = request.app.state.meeting
    session_id = state.create_session(config)
    return MeetingSetupResponse(session_id=session_id, status="ready")


@router.post("/end", response_model=MeetingSummary)
async def end_meeting(request: Request, session_id: str):
    state = request.app.state.meeting
    session = state.get_session(session_id)
    if not session:
        return MeetingSummary(
            executive_summary="No session found.",
            decisions=[],
            action_items=[],
            unresolved=[],
        )

    # Always save the full transcript to disk first — before any LLM call
    transcript_text = session.full_transcript
    _save_transcript(session)

    llm = request.app.state.llm
    try:
        summary = await llm.generate_summary(
            transcript=transcript_text,
            config=session.config,
            notes=session.notes_manager.get_all_text(),
        )
        # Attach the full (un-truncated) transcript to the response
        summary.full_transcript = transcript_text
    except Exception as e:
        logger.error(f"Summary generation failed: {e}", exc_info=True)
        state.end_session(session_id)
        # Return generic error message — don't expose internals (M3)
        return MeetingSummary(
            executive_summary=(
                "Summary generation failed. "
                "The meeting transcript was still captured. "
                "Check that LM Studio is running and try again."
            ),
            decisions=[],
            action_items=[],
            unresolved=["Summary generation failed — review transcript manually"],
            full_transcript=transcript_text,
        )
    state.end_session(session_id)
    return summary


@router.get("/health")
async def health():
    return {"status": "ok"}
