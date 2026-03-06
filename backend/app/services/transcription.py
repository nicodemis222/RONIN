import asyncio
import logging
import re
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

# Whisper hallucination filtering thresholds
NO_SPEECH_THRESHOLD = settings.whisper_no_speech_threshold
LOGPROB_THRESHOLD = settings.whisper_logprob_threshold
COMPRESSION_THRESHOLD = settings.whisper_compression_threshold


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

        # Filter out non-speech segments (music, noise, hallucinations)
        new_text = self._filter_segments(output)

        # Log length only — avoid logging sensitive meeting content (H6)
        logger.info(f"Whisper transcribed {len(new_text)} chars")

        if new_text == self.previous_text:
            return None

        delta = self._extract_delta(self.previous_text, new_text)
        self.previous_text = new_text

        if not delta.strip():
            return None

        # Final check: reject hallucinated repetition in the delta itself
        if self._is_repetitive(delta):
            logger.info("Rejected repetitive hallucination in delta")
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

    def _filter_segments(self, output: dict) -> str:
        """Filter Whisper segments using quality metrics to reject non-speech.

        Whisper returns per-segment metrics:
        - no_speech_prob: probability the segment is NOT speech (music, noise)
        - avg_logprob: average log-probability (low = Whisper unsure)
        - compression_ratio: text repetitiveness (high = hallucinated loops)

        When music plays, Whisper hallucinates repetitive text with high
        no_speech_prob and low confidence. This filter catches those cases.
        """
        segments = output.get("segments", [])
        if not segments:
            return output.get("text", "").strip()

        kept_texts = []
        for seg in segments:
            no_speech = seg.get("no_speech_prob", 0.0)
            avg_logprob = seg.get("avg_logprob", 0.0)
            compression = seg.get("compression_ratio", 1.0)
            text = seg.get("text", "").strip()

            if not text:
                continue

            # Reject: high probability of non-speech (music, background noise)
            if no_speech > NO_SPEECH_THRESHOLD:
                logger.info(
                    f"Filtered non-speech segment (no_speech_prob={no_speech:.2f}): "
                    f"{len(text)} chars"
                )
                continue

            # Reject: Whisper very unsure about what it heard
            if avg_logprob < LOGPROB_THRESHOLD:
                logger.info(
                    f"Filtered low-confidence segment (avg_logprob={avg_logprob:.2f}): "
                    f"{len(text)} chars"
                )
                continue

            # Reject: highly repetitive text (hallucination on loops/music)
            if compression > COMPRESSION_THRESHOLD:
                logger.info(
                    f"Filtered repetitive segment (compression={compression:.2f}): "
                    f"{len(text)} chars"
                )
                continue

            kept_texts.append(text)

        filtered_text = " ".join(kept_texts).strip()
        total = len(segments)
        kept = len(kept_texts)
        if kept < total:
            logger.info(f"Segment filter: kept {kept}/{total} segments")

        return filtered_text

    @staticmethod
    def _is_repetitive(text: str) -> bool:
        """Detect hallucinated repetition patterns in text.

        When Whisper receives music or sustained noise, it often produces
        highly repetitive output like 'you you you you' or loops of the same
        phrase. This catches those patterns even if per-segment metrics pass.
        """
        words = text.strip().split()
        if len(words) < 4:
            return False

        # Check if a single word dominates (>60% of all words)
        from collections import Counter
        counts = Counter(w.lower() for w in words)
        most_common_count = counts.most_common(1)[0][1]
        if most_common_count / len(words) > 0.6:
            return True

        # Check for short repeating phrases (2-4 word loops)
        text_lower = text.lower().strip()
        for phrase_len in range(2, 5):
            phrase_words = words[:phrase_len]
            phrase = " ".join(w.lower() for w in phrase_words)
            if len(phrase) < 3:
                continue
            # Count how many times the phrase appears
            occurrences = len(re.findall(re.escape(phrase), text_lower))
            if occurrences >= 3 and (occurrences * len(phrase)) / len(text_lower) > 0.5:
                return True

        return False

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
