from pydantic import BaseModel


class Decision(BaseModel):
    decision: str
    context: str


class ActionItem(BaseModel):
    action: str
    assignee: str = ""
    deadline: str = ""


class MeetingSummary(BaseModel):
    executive_summary: str
    decisions: list[Decision] = []
    action_items: list[ActionItem] = []
    unresolved: list[str] = []
