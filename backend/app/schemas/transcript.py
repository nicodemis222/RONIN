from pydantic import BaseModel


class TranscriptSegment(BaseModel):
    text: str
    full_text: str
    timestamp: str
    speaker: str = ""
    is_final: bool = True


class TranscriptUpdate(BaseModel):
    type: str = "transcript_update"
    data: TranscriptSegment
