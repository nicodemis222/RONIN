"""Tests for app/services/transcription.py — audio buffer, speech detection, delta.

IMPORTANT: mlx_whisper is mocked at the module level (see conftest.py).
These tests exercise the TranscriptionService without loading any model.
"""

import sys
from unittest.mock import MagicMock, patch

import numpy as np
import pytest

from app.config import settings

# Ensure the fake mlx_whisper module is in place before importing
assert "mlx_whisper" in sys.modules, "conftest.py should inject fake mlx_whisper"

from app.services.transcription import (
    COMPRESSION_THRESHOLD,
    LOGPROB_THRESHOLD,
    MAX_BUFFER_DURATION_SEC,
    MIN_SPEECH_DURATION_SEC,
    NO_SPEECH_THRESHOLD,
    SAMPLE_RATE,
    SILENCE_CHUNKS_FOR_BOUNDARY,
    SILENCE_THRESHOLD,
    TranscriptionService,
)


@pytest.fixture
def svc():
    """A fresh TranscriptionService with model loading disabled."""
    service = TranscriptionService(model_name="test-model")
    # Mark model as loaded so _ensure_model() is a no-op
    service._model_loaded = True
    return service


# ═══════════════════════════════════════════════════════════════════════════
# Audio buffer management
# ═══════════════════════════════════════════════════════════════════════════

class TestAddAudio:
    def test_add_audio_accumulates_buffer(self, svc):
        """Consecutive add_audio calls concatenate into the buffer."""
        chunk1 = np.zeros(1000, dtype=np.int16)
        chunk2 = np.ones(500, dtype=np.int16)
        svc.add_audio(chunk1)
        svc.add_audio(chunk2)
        assert len(svc.audio_buffer) == 1500

    def test_add_audio_caps_buffer_at_max(self, svc):
        """Buffer is capped at MAX_BUFFER_DURATION_SEC * SAMPLE_RATE samples."""
        max_samples = int(MAX_BUFFER_DURATION_SEC * SAMPLE_RATE)
        # Add more than the max
        huge_chunk = np.zeros(max_samples + 10000, dtype=np.int16)
        svc.add_audio(huge_chunk)
        assert len(svc.audio_buffer) == max_samples


# ═══════════════════════════════════════════════════════════════════════════
# Speech / silence detection
# ═══════════════════════════════════════════════════════════════════════════

class TestSpeechDetection:
    def test_speech_detection_activates_on_energy(self, svc):
        """A loud audio chunk sets speech_active=True and resets silence_count."""
        # Create a chunk with high energy (above SILENCE_THRESHOLD)
        loud_chunk = np.full(1000, SILENCE_THRESHOLD + 100, dtype=np.int16)
        svc.add_audio(loud_chunk)
        assert svc.speech_active is True
        assert svc.silence_count == 0

    def test_silence_detection_increments_count(self, svc):
        """A quiet chunk increments silence_count without changing speech_active."""
        # First, activate speech
        loud = np.full(1000, SILENCE_THRESHOLD + 100, dtype=np.int16)
        svc.add_audio(loud)
        assert svc.speech_active is True

        # Then add silence
        quiet = np.zeros(1000, dtype=np.int16)
        svc.add_audio(quiet)
        assert svc.silence_count == 1
        # speech_active is not cleared by silence alone
        assert svc.speech_active is True


# ═══════════════════════════════════════════════════════════════════════════
# try_transcribe guards
# ═══════════════════════════════════════════════════════════════════════════

class TestTryTranscribe:
    @pytest.mark.asyncio
    async def test_try_transcribe_skips_short_buffer(self, svc):
        """try_transcribe returns None if buffer < MIN_SPEECH_DURATION_SEC."""
        # Add less than 1 second of audio
        short = np.zeros(int(SAMPLE_RATE * 0.5), dtype=np.int16)
        svc.add_audio(short)
        result = await svc.try_transcribe()
        assert result is None

    @pytest.mark.asyncio
    async def test_try_transcribe_skips_if_already_running(self, svc):
        """try_transcribe returns None immediately if _transcribing is True."""
        svc._transcribing = True
        # Add enough audio to normally trigger
        svc.audio_buffer = np.zeros(int(SAMPLE_RATE * 5), dtype=np.int16)
        svc.speech_active = True
        svc.silence_count = SILENCE_CHUNKS_FOR_BOUNDARY
        result = await svc.try_transcribe()
        assert result is None


# ═══════════════════════════════════════════════════════════════════════════
# _extract_delta
# ═══════════════════════════════════════════════════════════════════════════

class TestExtractDelta:
    def test_extract_delta_new_text(self, svc):
        """When there is no previous text, the entire current text is the delta."""
        delta = svc._extract_delta("", "Hello world")
        assert delta == "Hello world"

    def test_extract_delta_overlapping_text(self, svc):
        """Overlapping suffix from previous is removed from the delta."""
        previous = "The quick brown fox"
        current = "brown fox jumps over"
        delta = svc._extract_delta(previous, current)
        assert delta == "jumps over"

    def test_extract_delta_completely_new(self, svc):
        """When there is no overlap at all, the full current text is returned."""
        previous = "Alpha beta gamma"
        current = "Delta epsilon zeta"
        delta = svc._extract_delta(previous, current)
        assert delta == "Delta epsilon zeta"


# ═══════════════════════════════════════════════════════════════════════════
# reset_buffer
# ═══════════════════════════════════════════════════════════════════════════

class TestResetBuffer:
    def test_reset_buffer_clears_all(self, svc):
        """reset_buffer clears audio, previous text, speech state, and speaker tracker."""
        # Set up some state
        svc.audio_buffer = np.ones(5000, dtype=np.int16)
        svc._recent_speech_audio = np.ones(3000, dtype=np.int16)
        svc.previous_text = "Some old text"
        svc.speech_active = True
        svc.silence_count = 5

        svc.reset_buffer()

        assert len(svc.audio_buffer) == 0
        assert len(svc._recent_speech_audio) == 0
        assert svc.previous_text == ""
        assert svc.speech_active is False
        assert svc.silence_count == 0


# ═══════════════════════════════════════════════════════════════════════════
# _filter_segments — Whisper hallucination filtering
# ═══════════════════════════════════════════════════════════════════════════

class TestFilterSegments:
    def test_keeps_good_speech_segments(self, svc):
        """Segments with good metrics are kept."""
        output = {
            "text": "Hello how are you doing today",
            "segments": [
                {
                    "text": "Hello how are you doing today",
                    "no_speech_prob": 0.05,
                    "avg_logprob": -0.3,
                    "compression_ratio": 1.2,
                }
            ],
        }
        result = svc._filter_segments(output)
        assert result == "Hello how are you doing today"

    def test_filters_high_no_speech_prob(self, svc):
        """Segments with high no_speech_prob are rejected (music/noise)."""
        output = {
            "text": "you you you you you",
            "segments": [
                {
                    "text": "you you you you you",
                    "no_speech_prob": 0.85,
                    "avg_logprob": -0.5,
                    "compression_ratio": 1.5,
                }
            ],
        }
        result = svc._filter_segments(output)
        assert result == ""

    def test_filters_low_logprob(self, svc):
        """Segments with very low avg_logprob are rejected (Whisper unsure)."""
        output = {
            "text": "some uncertain text",
            "segments": [
                {
                    "text": "some uncertain text",
                    "no_speech_prob": 0.3,
                    "avg_logprob": -1.5,
                    "compression_ratio": 1.1,
                }
            ],
        }
        result = svc._filter_segments(output)
        assert result == ""

    def test_filters_high_compression(self, svc):
        """Segments with high compression ratio are rejected (repetitive hallucination)."""
        output = {
            "text": "LO incompetent LO incompetent LO incompetent",
            "segments": [
                {
                    "text": "LO incompetent LO incompetent LO incompetent",
                    "no_speech_prob": 0.3,
                    "avg_logprob": -0.5,
                    "compression_ratio": 3.0,
                }
            ],
        }
        result = svc._filter_segments(output)
        assert result == ""

    def test_keeps_good_segments_filters_bad(self, svc):
        """Mixed segments: good ones kept, bad ones filtered."""
        output = {
            "text": "Good speech here plus some music noise",
            "segments": [
                {
                    "text": "Good speech here",
                    "no_speech_prob": 0.05,
                    "avg_logprob": -0.3,
                    "compression_ratio": 1.2,
                },
                {
                    "text": "plus some music noise",
                    "no_speech_prob": 0.8,
                    "avg_logprob": -0.9,
                    "compression_ratio": 1.5,
                },
            ],
        }
        result = svc._filter_segments(output)
        assert result == "Good speech here"

    def test_fallback_when_no_segments(self, svc):
        """Falls back to raw text when output has no segments key."""
        output = {"text": "Some text without segments"}
        result = svc._filter_segments(output)
        assert result == "Some text without segments"

    def test_threshold_boundary_values(self, svc):
        """Segments exactly at threshold boundaries are kept (threshold is exclusive)."""
        output = {
            "text": "Boundary test",
            "segments": [
                {
                    "text": "Boundary test",
                    "no_speech_prob": NO_SPEECH_THRESHOLD,  # Equal, not above
                    "avg_logprob": LOGPROB_THRESHOLD,  # Equal, not below
                    "compression_ratio": COMPRESSION_THRESHOLD,  # Equal, not above
                }
            ],
        }
        result = svc._filter_segments(output)
        assert result == "Boundary test"


# ═══════════════════════════════════════════════════════════════════════════
# _is_repetitive — repetition pattern detection
# ═══════════════════════════════════════════════════════════════════════════

class TestIsRepetitive:
    def test_single_word_repetition(self, svc):
        """Detects single-word hallucination loops like 'you you you you you'."""
        assert TranscriptionService._is_repetitive("you you you you you") is True

    def test_phrase_repetition(self, svc):
        """Detects multi-word hallucination loops."""
        assert TranscriptionService._is_repetitive(
            "thank you thank you thank you thank you"
        ) is True

    def test_normal_speech_not_flagged(self, svc):
        """Normal speech with varied words is not flagged."""
        assert TranscriptionService._is_repetitive(
            "I went to the store and bought some groceries"
        ) is False

    def test_short_text_not_flagged(self, svc):
        """Very short text (< 4 words) is never flagged."""
        assert TranscriptionService._is_repetitive("you you you") is False

    def test_lo_incompetent_pattern(self, svc):
        """Catches the 'LO incompetent' pattern from the user's screenshot."""
        assert TranscriptionService._is_repetitive(
            "LO incompetent LO incompetent LO incompetent LO incompetent"
        ) is True
