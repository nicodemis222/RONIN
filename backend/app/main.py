from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.routers import meeting, ws
from app.services.llm_client import LLMClient
from app.services.meeting_state import MeetingStateManager
from app.services.transcription import TranscriptionService
from app.config import settings


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.transcription = TranscriptionService(model_name=settings.whisper_model)
    app.state.llm = LLMClient(base_url=settings.lm_studio_url)
    app.state.meeting = MeetingStateManager()
    yield
    app.state.transcription.cleanup()
    await app.state.llm.close()


app = FastAPI(title="Ronin Backend", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)
app.include_router(meeting.router, prefix="/meeting", tags=["meeting"])
app.include_router(ws.router, tags=["websocket"])
