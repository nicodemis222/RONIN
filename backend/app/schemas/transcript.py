from pydantic import BaseModel


class TranscriptSegment(BaseModel):
    text: str
    full_text: str
    timestamp: str
    speaker: str = ""


class TranscriptUpdate(BaseModel):
    type: str = "transcript_update"
    data: TranscriptSegment
