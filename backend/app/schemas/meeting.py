from pydantic import BaseModel, Field


class NotePayload(BaseModel):
    name: str = Field(max_length=200)
    content: str = Field(max_length=500_000)  # ~125 pages max per note


class MeetingSetupRequest(BaseModel):
    title: str = Field(max_length=200)
    goal: str = Field(max_length=1000)
    constraints: str = Field(default="", max_length=2000)
    notes: list[NotePayload] = Field(default=[], max_length=20)  # Max 20 notes


class MeetingSetupResponse(BaseModel):
    session_id: str
    status: str
