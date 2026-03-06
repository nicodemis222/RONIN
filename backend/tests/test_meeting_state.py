"""Tests for app/services/meeting_state.py — session lifecycle, transcript management."""

import uuid

import pytest

from app.schemas.meeting import MeetingSetupRequest
from app.schemas.transcript import TranscriptSegment
from app.services.meeting_state import MeetingStateManager


@pytest.fixture
def state():
    return MeetingStateManager()


@pytest.fixture
def config():
    return MeetingSetupRequest(
        title="Standup",
        goal="Status updates",
        constraints="",
        notes=[],
    )


class TestCreateSession:
    def test_create_session_returns_uuid(self, state, config):
        """create_session returns a valid UUID4 string."""
        session_id = state.create_session(config)
        # Should be parseable as a UUID
        parsed = uuid.UUID(session_id, version=4)
        assert str(parsed) == session_id

    def test_get_session_returns_session(self, state, config):
        """get_session with a valid id returns the MeetingSession."""
        session_id = state.create_session(config)
        session = state.get_session(session_id)
        assert session is not None
        assert session.session_id == session_id
        assert session.config.title == "Standup"

    def test_get_session_invalid_id_returns_none(self, state):
        """get_session with a non-existent id returns None."""
        assert state.get_session("not-a-real-id") is None


class TestActiveSession:
    def test_get_active_session(self, state, config):
        """The most recently created session is the active session."""
        session_id = state.create_session(config)
        active = state.get_active_session()
        assert active is not None
        assert active.session_id == session_id

    def test_end_session_clears_active(self, state, config):
        """Ending the active session sets the active session to None."""
        session_id = state.create_session(config)
        state.end_session(session_id)
        assert state.get_active_session() is None


class TestEndSession:
    def test_end_session_removes_from_memory(self, state, config):
        """Ended sessions are removed entirely (not just deactivated)."""
        session_id = state.create_session(config)
        state.end_session(session_id)
        assert state.get_session(session_id) is None


class TestTranscript:
    def test_append_transcript(self, state, config):
        """append_transcript adds a segment to the session."""
        session_id = state.create_session(config)
        session = state.get_session(session_id)
        seg = TranscriptSegment(
            text="Hello",
            full_text="Hello",
            timestamp="10:00:00",
            speaker="Speaker 1",
        )
        session.append_transcript(seg)
        assert len(session.transcript_segments) == 1
        assert session.transcript_segments[0].text == "Hello"

    def test_full_transcript_formatting(self, session_with_transcript):
        """full_transcript joins segments with speaker tags and timestamps."""
        session, _, _ = session_with_transcript
        transcript = session.full_transcript
        assert "[10:00:01] Speaker 1: Hello everyone" in transcript
        assert "[10:00:04] Speaker 2: Let us begin" in transcript
        assert "[10:00:07] Speaker 1: Sounds good" in transcript

    def test_recent_transcript_window(self, state, config):
        """get_recent_transcript returns only the last N segments."""
        session_id = state.create_session(config)
        session = state.get_session(session_id)

        # Add 50 segments
        for i in range(50):
            seg = TranscriptSegment(
                text=f"Segment {i}",
                full_text=f"Full {i}",
                timestamp=f"10:{i:02d}:00",
            )
            session.append_transcript(seg)

        # With minutes=0.5 -> segments_per_minute=20 -> count=10
        recent = session.get_recent_transcript(minutes=0.5)
        lines = recent.strip().split("\n")
        assert len(lines) == 10
        # Should contain the last 10 segments (40..49)
        assert "Segment 49" in recent
        assert "Segment 40" in recent
        assert "Segment 39" not in recent
