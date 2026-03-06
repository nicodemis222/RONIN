import logging
import os
import re
from datetime import datetime
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request

from app.config import settings
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
    if llm is None:
        # Transcription-only mode — no LLM configured
        state.end_session(session_id)
        return MeetingSummary(
            executive_summary=(
                "No LLM provider configured. "
                "The meeting transcript was captured successfully. "
                "Configure an LLM provider in Settings to get AI-generated summaries."
            ),
            decisions=[],
            action_items=[],
            unresolved=[],
            full_transcript=transcript_text,
        )

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
        return MeetingSummary(
            executive_summary=(
                "Summary generation failed. "
                "The meeting transcript was still captured. "
                "Check your LLM provider configuration and try again."
            ),
            decisions=[],
            action_items=[],
            unresolved=["Summary generation failed — review transcript manually"],
            full_transcript=transcript_text,
        )
    state.end_session(session_id)
    return summary


@router.get("/health")
async def health(request: Request, details: bool = False):
    if not details:
        return {"status": "ok"}

    # ── Detailed dependency report ───────────────────────────────────
    deps: dict = {}

    # Whisper model
    transcription = request.app.state.transcription
    deps["whisper"] = {
        "status": "loaded" if transcription._model_loaded else "available",
        "model": transcription.model_name,
    }

    # LLM provider
    llm = request.app.state.llm
    if llm is None:
        deps["llm"] = {
            "status": "none",
            "provider": settings.llm_provider,
            "detail": "Transcription-only mode",
        }
    else:
        if llm._detected_context:
            deps["llm"] = {
                "status": "ok",
                "provider": llm.provider.name,
                "context_length": llm._detected_context,
            }
        else:
            try:
                n_ctx = await llm.detect_context_length()
                deps["llm"] = {
                    "status": "ok",
                    "provider": llm.provider.name,
                    "context_length": n_ctx,
                }
            except Exception as e:
                deps["llm"] = {
                    "status": "error",
                    "provider": llm.provider.name,
                    "detail": str(e)[:200],
                }

    # Active meeting
    meeting = request.app.state.meeting
    active = meeting.get_active_session()
    deps["meeting"] = {
        "active": active is not None,
        "segments": len(active.transcript_segments) if active else 0,
    }

    overall = "ok" if all(
        d.get("status") in ("ok", "available", "loaded", "none")
        for d in deps.values()
        if "status" in d
    ) else "degraded"

    return {"status": overall, "dependencies": deps}


@router.post("/shutdown")
async def graceful_shutdown(request: Request):
    """Save any active meeting transcript and prepare for clean exit."""
    meeting = request.app.state.meeting
    active = meeting.get_active_session()
    transcript_saved = False
    segments = 0

    if active and active.transcript_segments:
        segments = len(active.transcript_segments)
        path = _save_transcript(active)
        transcript_saved = path is not None
        meeting.end_session(active.session_id)
        logger.info(f"Graceful shutdown: saved {segments} transcript segments")
    else:
        logger.info("Graceful shutdown: no active session to save")

    return {
        "status": "shutting_down",
        "transcript_saved": transcript_saved,
        "segments_saved": segments,
    }
