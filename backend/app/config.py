from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    host: str = "127.0.0.1"
    port: int = 8000
    lm_studio_url: str = "http://localhost:1234/v1"
    whisper_model: str = "mlx-community/whisper-small-mlx"
    sample_rate: int = 16000
    audio_chunk_seconds: float = 2.0
    max_buffer_seconds: float = 30.0
    llm_debounce_seconds: float = 10.0
    transcript_window_minutes: float = 1.5
    notes_max_context_chars: int = 3000


settings = Settings()
