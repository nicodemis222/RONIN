from pydantic import BaseModel


class Suggestion(BaseModel):
    tone: str
    text: str


class Risk(BaseModel):
    warning: str
    context: str


class NoteFact(BaseModel):
    fact: str
    source: str


class CopilotResponse(BaseModel):
    suggestions: list[Suggestion] = []
    follow_up_questions: list[str] = []
    risks: list[Risk] = []
    facts_from_notes: list[NoteFact] = []
