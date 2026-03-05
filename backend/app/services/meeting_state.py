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
        self.transcript_segments.append(segment)

    @property
    def full_transcript(self) -> str:
        return "\n".join(f"[{s.timestamp}] {s.text}" for s in self.transcript_segments)

    def get_recent_transcript(self, minutes: float | None = None) -> str:
        if not self.transcript_segments:
            return ""
        if minutes is None:
            minutes = settings.transcript_window_minutes
        # Use the last N segments as a rough proxy (each ~2-3 seconds)
        segments_per_minute = 20  # ~3 seconds per segment
        count = int(minutes * segments_per_minute)
        recent = self.transcript_segments[-count:]
        return "\n".join(f"[{s.timestamp}] {s.text}" for s in recent)


class MeetingStateManager:
    def __init__(self):
        self._sessions: dict[str, MeetingSession] = {}
        self._active_session_id: str | None = None

    def create_session(self, config: MeetingSetupRequest) -> str:
        session_id = str(uuid.uuid4())[:8]
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
