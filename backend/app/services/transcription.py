import asyncio
import logging
import time
from dataclasses import dataclass, field

import numpy as np

from app.config import settings
from app.services.speaker_tracker import SpeakerTracker

logger = logging.getLogger(__name__)

SAMPLE_RATE = settings.sample_rate
MIN_SPEECH_DURATION_SEC = 1.0
MAX_BUFFER_DURATION_SEC = settings.max_buffer_seconds
SILENCE_THRESHOLD = 500
SILENCE_CHUNKS_FOR_BOUNDARY = 3


@dataclass
class TranscriptionService:
    model_name: str = settings.whisper_model
    audio_buffer: np.ndarray = field(
        default_factory=lambda: np.array([], dtype=np.int16)
    )
    previous_text: str = ""
    speech_active: bool = False
    silence_count: int = 0
    _model_loaded: bool = False
    _transcribing: bool = False
    speaker_tracker: SpeakerTracker = field(
        default_factory=lambda: SpeakerTracker(threshold=settings.speaker_threshold)
    )
    _recent_speech_audio: np.ndarray = field(
        default_factory=lambda: np.array([], dtype=np.int16)
    )

    def _ensure_model(self):
        if not self._model_loaded:
            import mlx_whisper  # noqa: F401 - lazy import to avoid slow startup

            self._model_loaded = True

    def add_audio(self, chunk: np.ndarray):
        self.audio_buffer = np.concatenate([self.audio_buffer, chunk])

        max_samples = int(MAX_BUFFER_DURATION_SEC * SAMPLE_RATE)
        if len(self.audio_buffer) > max_samples:
            self.audio_buffer = self.audio_buffer[-max_samples:]

        energy = np.abs(chunk).mean()
        if energy > SILENCE_THRESHOLD:
            self.speech_active = True
            self.silence_count = 0
            # Accumulate speech audio for speaker identification.
            # Keep up to 5 seconds of recent speech for feature extraction.
            self._recent_speech_audio = np.concatenate(
                [self._recent_speech_audio, chunk]
            )
            max_speech = int(5.0 * SAMPLE_RATE)
            if len(self._recent_speech_audio) > max_speech:
                self._recent_speech_audio = self._recent_speech_audio[-max_speech:]
        else:
            self.silence_count += 1

    async def try_transcribe(self) -> dict | None:
        # Skip if a previous transcription is still running in the thread pool
        if self._transcribing:
            return None

        buffer_duration = len(self.audio_buffer) / SAMPLE_RATE

        if buffer_duration < MIN_SPEECH_DURATION_SEC:
            return None

        is_boundary = (
            self.speech_active and self.silence_count >= SILENCE_CHUNKS_FOR_BOUNDARY
        )
        enough_audio = buffer_duration >= 3.0

        logger.debug(
            f"try_transcribe: buf={buffer_duration:.1f}s, speech={self.speech_active}, "
            f"silence={self.silence_count}, boundary={is_boundary}, enough={enough_audio}"
        )

        if not (is_boundary or enough_audio):
            return None

        logger.info(f"Starting transcription ({buffer_duration:.1f}s buffer)")
        self._transcribing = True
        try:
            result = await self._transcribe_buffer()
        finally:
            self._transcribing = False

        if result is None:
            logger.info("Transcription returned no result (model error or no new text)")
            return None

        logger.info(f"Transcription result: {len(result['text'])} chars, speaker={result.get('speaker', '')}")

        if is_boundary:
            self.speech_active = False
            self.silence_count = 0

        return result

    async def _transcribe_buffer(self) -> dict | None:
        self._ensure_model()
        import mlx_whisper

        try:
            # Convert int16 PCM to float32 [-1.0, 1.0] — the format mlx_whisper expects.
            # By passing a numpy array directly (instead of a file path), we bypass
            # mlx_whisper's internal ffmpeg call, which isn't available in the bundled app.
            audio_float = self.audio_buffer.astype(np.float32) / 32768.0

            # CRITICAL: Run Whisper in a thread pool so it doesn't block the
            # asyncio event loop. mlx_whisper.transcribe() is synchronous and
            # takes 2-5 seconds. Without to_thread(), the entire backend freezes:
            # no WebSocket messages can be received or sent.
            output = await asyncio.to_thread(
                mlx_whisper.transcribe,
                audio_float,
                path_or_hf_repo=self.model_name,
                language="en",
                word_timestamps=True,
            )
        except Exception as e:
            logger.error(f"Whisper transcription failed: {e}", exc_info=True)
            return None

        new_text = output["text"].strip()
        # Log length only — avoid logging sensitive meeting content (H6)
        logger.info(f"Whisper transcribed {len(new_text)} chars")

        if new_text == self.previous_text:
            return None

        delta = self._extract_delta(self.previous_text, new_text)
        self.previous_text = new_text

        if not delta.strip():
            return None

        # Identify speaker from recent speech audio
        speaker = ""
        if len(self._recent_speech_audio) > 0:
            speaker = self.speaker_tracker.identify(
                self._recent_speech_audio, SAMPLE_RATE
            )
            # Clear speech buffer after identification so the next segment
            # gets a fresh fingerprint
            self._recent_speech_audio = np.array([], dtype=np.int16)

        return {
            "text": delta,
            "full_text": new_text,
            "timestamp": time.strftime("%H:%M:%S"),
            "speaker": speaker,
        }

    def _extract_delta(self, previous: str, current: str) -> str:
        if not previous:
            return current
        words_prev = previous.split()
        words_curr = current.split()

        for overlap_len in range(min(len(words_prev), len(words_curr)), 0, -1):
            if words_prev[-overlap_len:] == words_curr[:overlap_len]:
                return " ".join(words_curr[overlap_len:])

        return current

    def reset_buffer(self):
        self.audio_buffer = np.array([], dtype=np.int16)
        self._recent_speech_audio = np.array([], dtype=np.int16)
        self.previous_text = ""
        self.speech_active = False
        self.silence_count = 0
        self.speaker_tracker.reset()

    def cleanup(self):
        self.reset_buffer()
