"""Tests for the WebSocket audio handler (/ws/audio).

Covers auth, connection limits, audio validation, transcript flow,
copilot generation, and error handling.
"""

import asyncio
import struct
from unittest.mock import AsyncMock, MagicMock, patch

import numpy as np
import pytest
from fastapi.testclient import TestClient

from app.config import settings
from app.routers.ws import get_active_ws_count, reset_connections


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_audio_bytes(n_samples: int = 1600) -> bytes:
    """Create valid int16 PCM audio data (100ms at 16kHz by default)."""
    samples = np.zeros(n_samples, dtype=np.int16)
    return samples.tobytes()


def _make_loud_audio_bytes(n_samples: int = 1600) -> bytes:
    """Create high-energy int16 PCM audio (triggers speech detection)."""
    samples = np.full(n_samples, 10000, dtype=np.int16)
    return samples.tobytes()


# ---------------------------------------------------------------------------
# Auth Tests
# ---------------------------------------------------------------------------

class TestWebSocketAuth:
    """WebSocket authentication via query parameter."""

    def test_connect_without_token_rejected(self, client):
        """Connection with no token should be rejected with code 4001."""
        with pytest.raises(Exception):
            with client.websocket_connect("/ws/audio"):
                pass  # Should not reach here

    def test_connect_with_invalid_token_rejected(self, client):
        """Connection with wrong token should be rejected with code 4001."""
        with pytest.raises(Exception):
            with client.websocket_connect("/ws/audio?token=wrong-token"):
                pass

    def test_connect_with_valid_token_no_session(self, client, auth_token):
        """Valid token but no active session → accepted then closed with code 4000."""
        with client.websocket_connect(f"/ws/audio?token={auth_token}") as ws:
            # Server accepts the WS, then immediately closes with 4000
            # Attempting to send/receive should raise because it's closed
            with pytest.raises(Exception):
                ws.send_bytes(_make_audio_bytes())
                ws.receive_json()


# ---------------------------------------------------------------------------
# Connection & Session Tests
# ---------------------------------------------------------------------------

class TestWebSocketConnection:
    """WebSocket connection lifecycle tests."""

    def test_connect_with_active_session(self, client, auth_token, auth_headers, meeting_config):
        """Valid token + active session → connection accepted."""
        # Set up a meeting first
        resp = client.post("/meeting/setup", json=meeting_config, headers=auth_headers)
        assert resp.status_code == 200

        with client.websocket_connect(f"/ws/audio?token={auth_token}") as ws:
            # Send one audio chunk to verify connection works
            ws.send_bytes(_make_audio_bytes())
            # Connection was accepted — success

    def test_connection_limit_enforced(self, client, auth_token, auth_headers, meeting_config):
        """Only ws_max_connections (1) WebSocket connections allowed."""
        # Set up a meeting first
        client.post("/meeting/setup", json=meeting_config, headers=auth_headers)

        with client.websocket_connect(f"/ws/audio?token={auth_token}"):
            # First connection is accepted. Second should be rejected.
            with pytest.raises(Exception):
                with client.websocket_connect(f"/ws/audio?token={auth_token}"):
                    pass

    def test_connection_counter_resets_after_disconnect(
        self, client, auth_token, auth_headers, meeting_config
    ):
        """After a WebSocket disconnects, the slot is freed for a new connection."""
        client.post("/meeting/setup", json=meeting_config, headers=auth_headers)

        # First connection
        with client.websocket_connect(f"/ws/audio?token={auth_token}") as ws:
            ws.send_bytes(_make_audio_bytes())
            assert get_active_ws_count() == 1

        # After disconnect, counter should be 0
        assert get_active_ws_count() == 0

        # Second connection should succeed (slot freed)
        with client.websocket_connect(f"/ws/audio?token={auth_token}") as ws:
            ws.send_bytes(_make_audio_bytes())
            assert get_active_ws_count() == 1

    def test_reset_connections_clears_tracker(self, client, auth_token, auth_headers, meeting_config):
        """reset_connections() forcefully clears all tracked connections."""
        reset_connections()
        assert get_active_ws_count() == 0


# ---------------------------------------------------------------------------
# Audio Validation Tests
# ---------------------------------------------------------------------------

class TestAudioValidation:
    """Audio data validation in the WebSocket handler."""

    def test_odd_length_data_skipped(self, client, auth_token, auth_headers, meeting_config):
        """Odd-length byte data (not valid int16) should be silently skipped."""
        client.post("/meeting/setup", json=meeting_config, headers=auth_headers)

        with client.websocket_connect(f"/ws/audio?token={auth_token}") as ws:
            # Send odd-length data (3 bytes — not valid int16)
            ws.send_bytes(b"\x00\x01\x02")
            # Send valid audio after — connection should still work
            ws.send_bytes(_make_audio_bytes())

    def test_oversized_message_skipped(self, client, auth_token, auth_headers, meeting_config):
        """Messages exceeding ws_max_message_bytes should be silently skipped."""
        client.post("/meeting/setup", json=meeting_config, headers=auth_headers)

        with client.websocket_connect(f"/ws/audio?token={auth_token}") as ws:
            # Send oversized data (over 128KB limit)
            big_data = _make_audio_bytes(n_samples=settings.ws_max_message_bytes + 1000)
            ws.send_bytes(big_data)
            # Connection should still work
            ws.send_bytes(_make_audio_bytes())


# ---------------------------------------------------------------------------
# Transcript & Copilot Flow Tests
# ---------------------------------------------------------------------------

class TestTranscriptFlow:
    """End-to-end transcript and copilot response flow."""

    def test_transcript_update_sent_on_speech(
        self, client, auth_token, auth_headers, meeting_config, mock_llm
    ):
        """When transcription returns a result, a transcript_update message is sent."""
        client.post("/meeting/setup", json=meeting_config, headers=auth_headers)

        # Mock the transcription service to return a result on first call
        mock_transcription = client.app.state.transcription
        mock_transcription.add_audio = MagicMock()

        transcript_result = {
            "text": "Hello everyone",
            "full_text": "Hello everyone",
            "timestamp": "00:00:01",
            "speaker": "Speaker 1",
        }
        mock_transcription.try_transcribe = AsyncMock(
            side_effect=[transcript_result, None]
        )

        with client.websocket_connect(f"/ws/audio?token={auth_token}") as ws:
            ws.send_bytes(_make_audio_bytes())
            msg = ws.receive_json()
            assert msg["type"] == "transcript_update"
            assert msg["data"]["text"] == "Hello everyone"
            assert msg["data"]["speaker"] == "Speaker 1"

    def test_copilot_response_sent_after_debounce(
        self, client, auth_token, auth_headers, meeting_config, mock_llm
    ):
        """When debounce elapses and transcript exists, copilot response is sent."""
        client.post("/meeting/setup", json=meeting_config, headers=auth_headers)

        mock_transcription = client.app.state.transcription
        mock_transcription.add_audio = MagicMock()

        transcript_result = {
            "text": "Hello everyone",
            "full_text": "Hello everyone",
            "timestamp": "00:00:01",
            "speaker": "Speaker 1",
        }
        # Return transcript then None (to stop trying to read more)
        mock_transcription.try_transcribe = AsyncMock(
            side_effect=[transcript_result, None]
        )

        # Set debounce to 0 to ensure copilot fires immediately
        original_debounce = settings.llm_debounce_seconds
        settings.llm_debounce_seconds = 0.0
        try:
            with client.websocket_connect(f"/ws/audio?token={auth_token}") as ws:
                ws.send_bytes(_make_audio_bytes())
                # First message should be transcript_update
                msg1 = ws.receive_json()
                assert msg1["type"] == "transcript_update"

                # Send another chunk to give the copilot task time to complete
                ws.send_bytes(_make_audio_bytes())

                # Should get copilot_response
                msg2 = ws.receive_json()
                assert msg2["type"] == "copilot_response"
                assert len(msg2["data"]["suggestions"]) >= 1
        finally:
            settings.llm_debounce_seconds = original_debounce


# ---------------------------------------------------------------------------
# Error Handling Tests
# ---------------------------------------------------------------------------

class TestWebSocketErrorHandling:
    """Error handling within the WebSocket handler."""

    def test_transcription_error_sends_error_message(
        self, client, auth_token, auth_headers, meeting_config
    ):
        """If transcription raises an exception, an error message is sent to client."""
        client.post("/meeting/setup", json=meeting_config, headers=auth_headers)

        mock_transcription = client.app.state.transcription
        mock_transcription.add_audio = MagicMock()
        mock_transcription.try_transcribe = AsyncMock(
            side_effect=RuntimeError("Whisper crashed")
        )

        with client.websocket_connect(f"/ws/audio?token={auth_token}") as ws:
            ws.send_bytes(_make_audio_bytes())
            msg = ws.receive_json()
            assert msg["type"] == "error"
            assert "Transcription error" in msg["data"]["message"]

    def test_copilot_error_sends_error_message(
        self, client, auth_token, auth_headers, meeting_config, mock_llm
    ):
        """If LLM generation fails, an error message is sent to client."""
        client.post("/meeting/setup", json=meeting_config, headers=auth_headers)

        mock_transcription = client.app.state.transcription
        mock_transcription.add_audio = MagicMock()

        transcript_result = {
            "text": "Testing error",
            "full_text": "Testing error",
            "timestamp": "00:00:01",
            "speaker": "Speaker 1",
        }
        mock_transcription.try_transcribe = AsyncMock(
            side_effect=[transcript_result, None, None]
        )

        # Make LLM raise
        mock_llm.generate_copilot_response = AsyncMock(
            side_effect=RuntimeError("LLM Studio down")
        )

        original_debounce = settings.llm_debounce_seconds
        settings.llm_debounce_seconds = 0.0
        try:
            with client.websocket_connect(f"/ws/audio?token={auth_token}") as ws:
                ws.send_bytes(_make_audio_bytes())
                # Get transcript_update first
                msg1 = ws.receive_json()
                assert msg1["type"] == "transcript_update"

                # Send another chunk to let error propagate
                ws.send_bytes(_make_audio_bytes())

                # Should receive error message from copilot failure
                msg2 = ws.receive_json()
                assert msg2["type"] == "error"
                assert "Copilot error:" in msg2["data"]["message"] or "LLM" in msg2["data"]["message"]
        finally:
            settings.llm_debounce_seconds = original_debounce


# ---------------------------------------------------------------------------
# Internal Function Tests
# ---------------------------------------------------------------------------

class TestVerifyWsToken:
    """Unit tests for _verify_ws_token."""

    def test_valid_token(self):
        """Correct token returns True."""
        from app.routers.ws import _verify_ws_token

        mock_ws = MagicMock()
        mock_ws.query_params = {"token": settings.auth_token}
        assert _verify_ws_token(mock_ws) is True

    def test_invalid_token(self):
        """Wrong token returns False."""
        from app.routers.ws import _verify_ws_token

        mock_ws = MagicMock()
        mock_ws.query_params = {"token": "bad-token"}
        assert _verify_ws_token(mock_ws) is False

    def test_missing_token(self):
        """No token param returns False."""
        from app.routers.ws import _verify_ws_token

        mock_ws = MagicMock()
        mock_ws.query_params = {}
        assert _verify_ws_token(mock_ws) is False
