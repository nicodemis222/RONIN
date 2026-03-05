from pydantic import BaseModel


class NotePayload(BaseModel):
    name: str
    content: str


class MeetingSetupRequest(BaseModel):
    title: str
    goal: str
    constraints: str = ""
    notes: list[NotePayload] = []


class MeetingSetupResponse(BaseModel):
    session_id: str
    status: str
