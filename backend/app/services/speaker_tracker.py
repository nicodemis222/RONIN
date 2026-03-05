"""Lightweight speaker change detection using MFCC features.

Uses only numpy (no extra dependencies). Computes Mel-frequency cepstral
coefficients (MFCCs) — the standard for speaker identification — then
clusters speakers by cosine distance on the mean MFCC vector.

This is not a full diarization model (which would need pyannote or similar).
It's a practical heuristic that works well for 2-4 speakers in a meeting
captured as mixed system audio. Quality degrades with heavy crosstalk or
very similar voices.
"""

import logging

import numpy as np

logger = logging.getLogger(__name__)

# Minimum audio duration (seconds) to attempt speaker identification.
MIN_DURATION_SEC = 0.5

# MFCC parameters
N_MELS = 26
N_MFCC = 13
FRAME_SIZE = 0.025  # 25 ms frames
FRAME_STRIDE = 0.010  # 10 ms stride
MEL_LOW = 80.0
MEL_HIGH = 7600.0


def _hz_to_mel(hz: float) -> float:
    return 2595.0 * np.log10(1.0 + hz / 700.0)


def _mel_to_hz(mel: float) -> float:
    return 700.0 * (10.0 ** (mel / 2595.0) - 1.0)


def _mel_filterbank(n_fft: int, sr: int, n_mels: int = N_MELS) -> np.ndarray:
    """Create a mel-scale filterbank matrix."""
    mel_lo = _hz_to_mel(MEL_LOW)
    mel_hi = _hz_to_mel(min(MEL_HIGH, sr / 2))
    mel_points = np.linspace(mel_lo, mel_hi, n_mels + 2)
    hz_points = np.array([_mel_to_hz(m) for m in mel_points])
    bins = np.floor((n_fft + 1) * hz_points / sr).astype(int)

    fbank = np.zeros((n_mels, n_fft // 2 + 1))
    for i in range(n_mels):
        lo, mid, hi = bins[i], bins[i + 1], bins[i + 2]
        for j in range(lo, mid):
            fbank[i, j] = (j - lo) / max(mid - lo, 1)
        for j in range(mid, hi):
            fbank[i, j] = (hi - j) / max(hi - mid, 1)
    return fbank


def _compute_mfcc(audio: np.ndarray, sr: int) -> np.ndarray | None:
    """Compute mean MFCC vector across all frames.

    Returns a 1-D array of shape (N_MFCC,) or None if audio is too short.
    """
    frame_len = int(FRAME_SIZE * sr)
    frame_step = int(FRAME_STRIDE * sr)
    n = len(audio)

    if n < frame_len:
        return None

    # Pre-emphasis
    emphasized = np.append(audio[0], audio[1:] - 0.97 * audio[:-1])

    # Frame the signal
    n_frames = 1 + (n - frame_len) // frame_step
    indices = (
        np.tile(np.arange(frame_len), (n_frames, 1))
        + np.tile(np.arange(0, n_frames * frame_step, frame_step), (frame_len, 1)).T
    )
    frames = emphasized[indices]

    # Apply Hamming window
    frames *= np.hamming(frame_len)

    # FFT → power spectrum
    n_fft = frame_len
    mag = np.abs(np.fft.rfft(frames, n_fft))
    power = (mag ** 2) / n_fft

    # Apply mel filterbank
    fbank = _mel_filterbank(n_fft, sr)
    mel_spec = np.dot(power, fbank.T)
    mel_spec = np.where(mel_spec == 0, np.finfo(float).eps, mel_spec)
    log_mel = np.log(mel_spec)

    # DCT to get MFCCs (type-II DCT, manual implementation)
    n_filters = log_mel.shape[1]
    dct_matrix = np.zeros((N_MFCC, n_filters))
    for k in range(N_MFCC):
        for i in range(n_filters):
            dct_matrix[k, i] = np.cos(np.pi * k * (2 * i + 1) / (2 * n_filters))
    dct_matrix *= np.sqrt(2.0 / n_filters)

    mfcc = np.dot(log_mel, dct_matrix.T)  # (n_frames, N_MFCC)

    # Mean + standard deviation across frames for a robust embedding
    mean = mfcc.mean(axis=0)
    std = mfcc.std(axis=0)
    return np.concatenate([mean, std])  # (2 * N_MFCC,)


def _cosine_distance(a: np.ndarray, b: np.ndarray) -> float:
    """Cosine distance: 0 = identical, 2 = opposite."""
    dot = float(np.dot(a, b))
    norm = float(np.linalg.norm(a) * np.linalg.norm(b))
    if norm < 1e-10:
        return 2.0
    return 1.0 - dot / norm


class SpeakerTracker:
    def __init__(self, threshold: float = 0.08, max_speakers: int = 8):
        """
        Args:
            threshold: Cosine distance threshold for assigning a new speaker.
                       Lower = more sensitive (more speakers detected).
                       Real speech inter-speaker distances are typically 0.02-0.3.
                       Default 0.08 balances sensitivity vs false splits.
            max_speakers: Cap on number of distinct speakers tracked.
        """
        self.threshold = threshold
        self.max_speakers = max_speakers
        self._centroids: dict[str, np.ndarray] = {}  # label -> MFCC centroid
        self._counts: dict[str, int] = {}  # label -> segment count
        self._next_id = 1
        self._last_speaker = ""

    def identify(self, audio: np.ndarray, sample_rate: int = 16000) -> str:
        """Identify the speaker for the given audio segment.

        Returns a label like "Speaker 1", "Speaker 2", etc.
        """
        duration = len(audio) / sample_rate
        if duration < MIN_DURATION_SEC:
            return self._last_speaker or self._make_label()

        # Convert int16 → float32
        if audio.dtype == np.int16:
            audio = audio.astype(np.float32) / 32768.0

        # Skip silence
        rms = float(np.sqrt(np.mean(audio ** 2)))
        if rms < 0.005:
            return self._last_speaker or self._make_label()

        features = _compute_mfcc(audio, sample_rate)
        if features is None:
            return self._last_speaker or self._make_label()

        # First speaker
        if not self._centroids:
            label = self._make_label()
            self._centroids[label] = features
            self._counts[label] = 1
            self._last_speaker = label
            logger.info(f"New speaker detected: {label}")
            return label

        # Find closest existing speaker by cosine distance
        min_dist = float("inf")
        closest = ""
        for label, centroid in self._centroids.items():
            dist = _cosine_distance(features, centroid)
            if dist < min_dist:
                min_dist = dist
                closest = label

        logger.debug(
            f"Speaker distance: closest={closest} dist={min_dist:.4f} "
            f"threshold={self.threshold}"
        )

        if min_dist <= self.threshold or len(self._centroids) >= self.max_speakers:
            # Match existing speaker — update centroid with exponential moving average
            alpha = 0.2
            self._centroids[closest] = (
                alpha * features + (1 - alpha) * self._centroids[closest]
            )
            self._counts[closest] = self._counts.get(closest, 0) + 1
            self._last_speaker = closest
            return closest
        else:
            # New speaker
            label = self._make_label()
            self._centroids[label] = features
            self._counts[label] = 1
            self._last_speaker = label
            logger.info(
                f"New speaker detected: {label} "
                f"(cosine_dist={min_dist:.3f} > threshold={self.threshold})"
            )
            return label

    def reset(self):
        """Reset tracker for a new meeting."""
        self._centroids.clear()
        self._counts.clear()
        self._next_id = 1
        self._last_speaker = ""

    def speaker_count(self) -> int:
        return len(self._centroids)

    def _make_label(self) -> str:
        label = f"Speaker {self._next_id}"
        self._next_id += 1
        return label
