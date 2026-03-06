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
    MAX_BUFFER_DURATION_SEC,
    MIN_SPEECH_DURATION_SEC,
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
