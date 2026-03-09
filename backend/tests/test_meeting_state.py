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

    def test_partial_replaces_regardless_of_speaker(self, state, config):
        """Partial segments always replace the previous partial, even with different speakers.

        Speaker identification is non-deterministic — the same audio may be
        tagged as 'Speaker 1' or '' across consecutive partials. The replacement
        logic must not depend on speaker match.
        """
        session_id = state.create_session(config)
        session = state.get_session(session_id)

        # Final segment from Speaker 1
        session.append_transcript(TranscriptSegment(
            text="Hello",
            full_text="Hello",
            timestamp="10:00:00",
            speaker="Speaker 1",
            is_final=True,
        ))
        # Partial with blank speaker (speaker ID failed)
        session.append_transcript(TranscriptSegment(
            text="How are",
            full_text="How are",
            timestamp="10:00:02",
            speaker="",
            is_final=False,
        ))
        # Another partial with Speaker 1 (speaker ID succeeded this time)
        session.append_transcript(TranscriptSegment(
            text="How are you doing today",
            full_text="How are you doing today",
            timestamp="10:00:03",
            speaker="Speaker 1",
            is_final=False,
        ))

        # Should be 2 segments: the final + one partial (replaced in-place)
        assert len(session.transcript_segments) == 2
        assert session.transcript_segments[1].text == "How are you doing today"

    def test_full_transcript_only_includes_finals(self, state, config):
        """full_transcript excludes partials — they are transient display-only data."""
        session_id = state.create_session(config)
        session = state.get_session(session_id)

        session.append_transcript(TranscriptSegment(
            text="First utterance",
            full_text="First utterance",
            timestamp="10:00:00",
            speaker="Speaker 1",
            is_final=True,
        ))
        session.append_transcript(TranscriptSegment(
            text="Second partial",
            full_text="Second partial",
            timestamp="10:00:03",
            speaker="Speaker 1",
            is_final=False,
        ))
        session.append_transcript(TranscriptSegment(
            text="Second utterance complete",
            full_text="Second utterance complete",
            timestamp="10:00:05",
            speaker="Speaker 1",
            is_final=True,
        ))
        session.append_transcript(TranscriptSegment(
            text="Third partial in progress",
            full_text="Third partial in progress",
            timestamp="10:00:08",
            speaker="",
            is_final=False,
        ))

        transcript = session.full_transcript
        assert "First utterance" in transcript
        assert "Second utterance complete" in transcript
        # The last segment is included even if partial (in-progress speech)
        assert "Third partial in progress" in transcript
        # Intermediate partial should NOT appear
        assert "Second partial" not in transcript
        # Should be exactly 3 lines
        assert len(transcript.strip().split("\n")) == 3

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
