import uuid
from dataclasses import dataclass, field
from datetime import datetime

from app.services.notes_manager import NotesManager
from app.schemas.meeting import MeetingSetupRequest
from app.schemas.transcript import TranscriptSegment
from app.config import settings


@dataclass
class MeetingSession:
    session_id: str
    config: MeetingSetupRequest
    notes_manager: NotesManager
    transcript_segments: list[TranscriptSegment] = field(default_factory=list)
    started_at: datetime = field(default_factory=datetime.now)

    def append_transcript(self, segment: TranscriptSegment):
        """Append or replace a transcript segment.

        When the previous segment is a partial (non-final), ALWAYS replace
        it — regardless of speaker label. Speaker identification is
        non-deterministic (sometimes "", sometimes "Speaker N" for the same
        audio), so checking speaker match caused partials to leak into the
        transcript as duplicate lines.

        When the previous segment is final and a new segment arrives, it
        starts a new line in the transcript.
        """
        if (
            self.transcript_segments
            and not self.transcript_segments[-1].is_final
        ):
            # Replace previous partial with updated (or final) version
            self.transcript_segments[-1] = segment
        else:
            self.transcript_segments.append(segment)

    @staticmethod
    def _format_segment(s) -> str:
        speaker_tag = f" {s.speaker}:" if s.speaker else ""
        return f"[{s.timestamp}]{speaker_tag} {s.text}"

    @property
    def full_transcript(self) -> str:
        """Return only final (committed) segments for export.

        Partials are transient display-only data that get superseded by
        the next partial or final. Including them in the export would
        create massive duplication (the same utterance growing line by line).
        The last segment is included even if partial (in-progress speech).
        """
        finals = [
            s for i, s in enumerate(self.transcript_segments)
            if s.is_final or i == len(self.transcript_segments) - 1
        ]
        return "\n".join(self._format_segment(s) for s in finals)

    def get_recent_transcript(self, minutes: float | None = None) -> str:
        if not self.transcript_segments:
            return ""
        if minutes is None:
            minutes = settings.transcript_window_minutes
        # Use the last N segments as a rough proxy (each ~2-3 seconds)
        segments_per_minute = 20  # ~3 seconds per segment
        count = int(minutes * segments_per_minute)
        recent = self.transcript_segments[-count:]
        return "\n".join(self._format_segment(s) for s in recent)


class MeetingStateManager:
    def __init__(self):
        self._sessions: dict[str, MeetingSession] = {}
        self._active_session_id: str | None = None

    def create_session(self, config: MeetingSetupRequest) -> str:
        # Use full UUID4 for session IDs — not truncated (H5)
        session_id = str(uuid.uuid4())
        notes_mgr = NotesManager()
        notes_mgr.load_notes([n.model_dump() for n in config.notes])

        session = MeetingSession(
            session_id=session_id,
            config=config,
            notes_manager=notes_mgr,
        )
        self._sessions[session_id] = session
        self._active_session_id = session_id
        return session_id

    def get_session(self, session_id: str) -> MeetingSession | None:
        return self._sessions.get(session_id)

    def get_active_session(self) -> MeetingSession | None:
        if self._active_session_id:
            return self._sessions.get(self._active_session_id)
        return None

    def end_session(self, session_id: str):
        if self._active_session_id == session_id:
            self._active_session_id = None
        # Remove session data from memory to prevent leaks (M6)
        self._sessions.pop(session_id, None)
