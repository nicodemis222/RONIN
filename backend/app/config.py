import secrets

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    host: str = "127.0.0.1"
    port: int = 8000
    lm_studio_url: str = "http://localhost:1234/v1"
    whisper_model: str = "mlx-community/whisper-small-mlx"
    sample_rate: int = 16000
    audio_chunk_seconds: float = 2.0
    max_buffer_seconds: float = 15.0
    llm_debounce_seconds: float = 10.0
    transcript_window_minutes: float = 5.0
    notes_max_context_chars: int = 3000
    llm_max_transcript_chars: int = 12000  # Truncate transcript to fit LLM context
    speaker_threshold: float = 0.08  # Cosine distance threshold for speaker change detection

    # Whisper hallucination filtering thresholds
    # Segments with no_speech_prob above this are likely non-speech (music, noise)
    whisper_no_speech_threshold: float = 0.6
    # Segments with avg_logprob below this indicate low Whisper confidence
    whisper_logprob_threshold: float = -1.0
    # Segments with compression_ratio above this are likely repetitive hallucination
    whisper_compression_threshold: float = 2.4

    # Security: auth token generated at startup, passed to Swift app via stdout
    auth_token: str = ""

    # LLM provider configuration
    llm_provider: str = "local"  # "local", "anthropic", "openai", "none"
    llm_model: str = ""  # Override default model for the chosen provider
    anthropic_api_key: str = ""
    openai_api_key: str = ""
    openai_base_url: str = "https://api.openai.com/v1"

    # WebSocket limits
    ws_max_message_bytes: int = 128_000  # ~4 seconds of 16kHz int16 audio
    ws_max_connections: int = 1  # Only one active meeting at a time


settings = Settings()

# Generate a fresh auth token each time the backend starts.
# The Swift app reads this from the backend's stdout to authenticate.
if not settings.auth_token:
    settings.auth_token = secrets.token_urlsafe(32)
