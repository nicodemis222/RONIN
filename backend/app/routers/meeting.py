import logging

from fastapi import APIRouter, HTTPException, Request

from app.schemas.meeting import MeetingSetupRequest, MeetingSetupResponse
from app.schemas.summary import MeetingSummary

router = APIRouter()
logger = logging.getLogger(__name__)


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

    llm = request.app.state.llm
    try:
        summary = await llm.generate_summary(
            transcript=session.full_transcript,
            config=session.config,
            notes=session.notes_manager.get_all_text(),
        )
    except Exception as e:
        logger.error(f"Summary generation failed: {e}", exc_info=True)
        # Return a partial summary instead of a hard 503 error
        # so the user at least sees their transcript wasn't lost
        state.end_session(session_id)
        return MeetingSummary(
            executive_summary=(
                f"Summary generation failed ({e}). "
                "The meeting transcript was still captured. "
                "Check that LM Studio is running and try again."
            ),
            decisions=[],
            action_items=[],
            unresolved=["Summary generation failed — review transcript manually"],
        )
    state.end_session(session_id)
    return summary


@router.get("/health")
async def health():
    return {"status": "ok"}
