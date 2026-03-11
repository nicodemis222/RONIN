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

        # During active transcription, allow the buffer to grow beyond
        # max so speech arriving while Whisper processes isn't trimmed
        # away. The forced-final mechanism properly slices the buffer
        # after transcription completes. Safety cap at 2x prevents
        # unbounded growth if transcription hangs (~320KB max).
        if self._transcribing:
            max_samples = int(MAX_BUFFER_DURATION_SEC * SAMPLE_RATE * 2)
        else:
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

        # Force a final when the buffer is near capacity. Without this,
        # continuous speech exceeding MAX_BUFFER_DURATION_SEC silently loses
        # early text: the buffer trims old audio, Whisper only sees what
        # remains, and the partial replaces the previous partial — so all
        # text before the trim window is permanently lost.
        buffer_near_full = buffer_duration >= MAX_BUFFER_DURATION_SEC * 0.85

        logger.debug(
            f"try_transcribe: buf={buffer_duration:.1f}s, speech={self.speech_active}, "
            f"silence={self.silence_count}, boundary={is_boundary}, "
            f"enough={enough_audio}, near_full={buffer_near_full}"
        )

        if not (is_boundary or enough_audio):
            return None

        logger.info(f"Starting transcription ({buffer_duration:.1f}s buffer)")

        # Capture buffer length BEFORE Whisper starts. Whisper runs in a
        # thread pool for 2-5 seconds; during that time add_audio() keeps
        # growing the buffer. After a final commit, we slice the buffer
        # to keep only samples that arrived during processing — otherwise
        # those 2-5 seconds of speech are silently discarded.
        samples_at_snapshot = len(self.audio_buffer)

        self._transcribing = True
        try:
            result = await self._transcribe_buffer()
        finally:
            self._transcribing = False

        if result is None:
            logger.info("Transcription returned no result (model error or no new text)")
            return None

        # Tag segment as final when:
        # 1. Silence detected after speech (natural boundary), OR
        # 2. Buffer is near capacity (forced commit to prevent text loss)
        is_final = is_boundary or buffer_near_full
        result["is_final"] = is_final

        reason = "boundary" if is_boundary else ("buffer-full" if buffer_near_full else "partial")
        logger.info(
            f"Transcription result: {len(result['text'])} chars, "
            f"speaker={result.get('speaker', '')}, "
            f"{reason}"
        )

        if is_final:
            if is_boundary:
                self.speech_active = False
            self.silence_count = 0
            # Keep audio that arrived DURING transcription. Without this,
            # 2-5 seconds of speech recorded while Whisper was processing
            # would be permanently lost on every commit cycle. Over a
            # 30-minute meeting, this adds up to minutes of missing text.
            if len(self.audio_buffer) > samples_at_snapshot:
                self.audio_buffer = self.audio_buffer[samples_at_snapshot:]
                logger.info(
                    f"Buffer sliced: kept {len(self.audio_buffer) / SAMPLE_RATE:.1f}s "
                    f"of audio that arrived during transcription"
                )
            else:
                self.audio_buffer = np.array([], dtype=np.int16)
            self.previous_text = ""

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

        # Check if there is genuinely new content (not just punctuation drift)
        delta = self._extract_delta(self.previous_text, new_text)
        if not delta.strip():
            return None

        # Reject hallucinated repetition in the new content
        if self._is_repetitive(delta):
            logger.info("Rejected repetitive hallucination in delta")
            return None

        self.previous_text = new_text

        # Identify speaker from recent speech audio
        speaker = ""
        if len(self._recent_speech_audio) > 0:
            speaker = self.speaker_tracker.identify(
                self._recent_speech_audio, SAMPLE_RATE
            )
            # Clear speech buffer after identification so the next segment
            # gets a fresh fingerprint
            self._recent_speech_audio = np.array([], dtype=np.int16)

        # Return the full utterance text (not the delta). The UI replaces
        # the previous partial segment in-place, creating a streaming effect
        # where text grows word-by-word. Only finals get persisted to the
        # transcript, so the exported file has each utterance exactly once.
        return {
            "text": new_text,
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
