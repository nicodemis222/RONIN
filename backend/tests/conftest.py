"""Shared fixtures for the RONIN backend test suite."""

import sys
from contextlib import asynccontextmanager
from types import ModuleType
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient

from app.config import settings
from app.schemas.copilot import CopilotResponse, NoteFact, Risk, Suggestion
from app.schemas.meeting import MeetingSetupRequest
from app.schemas.summary import MeetingSummary
from app.schemas.transcript import TranscriptSegment
from app.routers.ws import reset_connections
from app.services.meeting_state import MeetingStateManager


# ---------------------------------------------------------------------------
# Prevent import of mlx_whisper — it requires Apple Silicon / MLX runtime.
# We inject a fake module so TranscriptionService can be imported safely.
# ---------------------------------------------------------------------------
_fake_mlx = ModuleType("mlx_whisper")
_fake_mlx.transcribe = MagicMock(return_value={"text": ""})
sys.modules.setdefault("mlx_whisper", _fake_mlx)


# ---------------------------------------------------------------------------
# Auth fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def auth_token():
    """The auth token generated at backend startup."""
    return settings.auth_token


@pytest.fixture
def auth_headers(auth_token):
    """Headers dict with a valid Bearer token."""
    return {"Authorization": f"Bearer {auth_token}"}


# ---------------------------------------------------------------------------
# Mock LLM fixture
# ---------------------------------------------------------------------------

@pytest.fixture
def mock_llm():
    """A mock LLMClient that returns canned CopilotResponse / MeetingSummary."""
    llm = AsyncMock()
    llm.generate_copilot_response = AsyncMock(
        return_value=CopilotResponse(
            suggestions=[Suggestion(tone="direct", text="Consider X")],
            follow_up_questions=["What about Y?"],
            risks=[Risk(warning="Budget risk", context="Over by 10%")],
            facts_from_notes=[NoteFact(fact="Fact A", source="notes.md")],
        )
    )
    llm.generate_summary = AsyncMock(
        return_value=MeetingSummary(
            executive_summary="Great meeting.",
            decisions=[],
            action_items=[],
            unresolved=[],
        )
    )
    llm.detect_context_length = AsyncMock(return_value=8192)
    llm.close = AsyncMock()
    return llm


# ---------------------------------------------------------------------------
# FastAPI TestClient with mocked heavy services
# ---------------------------------------------------------------------------

@pytest.fixture
def client(mock_llm):
    """TestClient whose lifespan skips Whisper model loading and LLM Studio."""
    from app.main import app

    @asynccontextmanager
    async def _test_lifespan(application):
        # Clear stale connection tracking so each test starts fresh
        reset_connections()

        # Use a lightweight mock TranscriptionService — no Whisper
        mock_transcription = MagicMock()
        mock_transcription.cleanup = MagicMock()

        application.state.transcription = mock_transcription
        application.state.llm = mock_llm
        application.state.meeting = MeetingStateManager()
        yield
        mock_transcription.cleanup()

    original_lifespan = app.router.lifespan_context
    app.router.lifespan_context = _test_lifespan
    try:
        with TestClient(app) as c:
            yield c
    finally:
        app.router.lifespan_context = original_lifespan


# ---------------------------------------------------------------------------
# Meeting config fixture
# ---------------------------------------------------------------------------

@pytest.fixture
def meeting_config():
    """A valid MeetingSetupRequest as a plain dict (for JSON posting)."""
    return {
        "title": "Sprint Planning",
        "goal": "Decide sprint scope",
        "constraints": "Must ship by Friday",
        "notes": [
            {"name": "backlog.md", "content": "Item 1: Auth flow\nItem 2: Dashboard"},
        ],
    }


# ---------------------------------------------------------------------------
# Session with transcript segments
# ---------------------------------------------------------------------------

@pytest.fixture
def session_with_transcript():
    """Create and return a MeetingSession pre-loaded with transcript segments."""
    config = MeetingSetupRequest(
        title="Test Meeting",
        goal="Test goal",
        constraints="",
        notes=[],
    )
    state = MeetingStateManager()
    session_id = state.create_session(config)
    session = state.get_session(session_id)

    segments = [
        TranscriptSegment(
            text="Hello everyone",
            full_text="Hello everyone",
            timestamp="10:00:01",
            speaker="Speaker 1",
        ),
        TranscriptSegment(
            text="Let us begin",
            full_text="Hello everyone let us begin",
            timestamp="10:00:04",
            speaker="Speaker 2",
        ),
        TranscriptSegment(
            text="Sounds good",
            full_text="Hello everyone let us begin sounds good",
            timestamp="10:00:07",
            speaker="Speaker 1",
        ),
    ]
    for seg in segments:
        session.append_transcript(seg)

    return session, state, session_id
