"""Tests for the REST API endpoints in app/routers/meeting.py."""

from unittest.mock import AsyncMock, patch

import pytest


# ── Health endpoint ───────────────────────────────────────────────────────

class TestHealth:
    def test_health_returns_ok(self, client):
        """GET /meeting/health requires no auth and returns {"status": "ok"}."""
        resp = client.get("/meeting/health")
        assert resp.status_code == 200
        assert resp.json() == {"status": "ok"}


# ── Setup meeting ─────────────────────────────────────────────────────────

class TestSetupMeeting:
    def test_setup_meeting_success(self, client, auth_headers, meeting_config):
        """POST /meeting/setup with valid auth returns session_id + status=ready."""
        resp = client.post("/meeting/setup", json=meeting_config, headers=auth_headers)
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] == "ready"
        assert "session_id" in data
        # Session ID should be a full UUID4
        assert len(data["session_id"]) == 36

    def test_setup_meeting_unauthorized(self, client, meeting_config):
        """POST /meeting/setup without auth header returns 401."""
        resp = client.post("/meeting/setup", json=meeting_config)
        assert resp.status_code == 401

    def test_setup_meeting_invalid_token(self, client, meeting_config):
        """POST /meeting/setup with a wrong Bearer token returns 401."""
        headers = {"Authorization": "Bearer totally-wrong-token"}
        resp = client.post("/meeting/setup", json=meeting_config, headers=headers)
        assert resp.status_code == 401

    def test_setup_meeting_missing_title(self, client, auth_headers):
        """POST /meeting/setup without 'title' returns 422 validation error."""
        payload = {"goal": "Decide sprint scope"}
        resp = client.post("/meeting/setup", json=payload, headers=auth_headers)
        assert resp.status_code == 422

    def test_setup_meeting_missing_goal(self, client, auth_headers):
        """POST /meeting/setup without 'goal' returns 422 validation error."""
        payload = {"title": "Sprint Planning"}
        resp = client.post("/meeting/setup", json=payload, headers=auth_headers)
        assert resp.status_code == 422


# ── End meeting ───────────────────────────────────────────────────────────

class TestEndMeeting:
    def test_end_meeting_no_session(self, client, auth_headers):
        """POST /meeting/end with a bogus session_id returns a generic summary."""
        resp = client.post(
            "/meeting/end",
            params={"session_id": "nonexistent-id"},
            headers=auth_headers,
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["executive_summary"] == "No session found."
        assert data["decisions"] == []
        assert data["action_items"] == []

    def test_end_meeting_success(self, client, auth_headers, meeting_config, mock_llm):
        """POST /meeting/end with a valid session returns the LLM summary."""
        # First, create a session
        setup_resp = client.post(
            "/meeting/setup", json=meeting_config, headers=auth_headers
        )
        session_id = setup_resp.json()["session_id"]

        # Patch _save_transcript to avoid filesystem side effects
        with patch("app.routers.meeting._save_transcript", return_value=None):
            resp = client.post(
                "/meeting/end",
                params={"session_id": session_id},
                headers=auth_headers,
            )
        assert resp.status_code == 200
        data = resp.json()
        assert data["executive_summary"] == "Great meeting."

    def test_end_meeting_llm_failure(self, client, auth_headers, meeting_config, mock_llm):
        """When the LLM fails, /meeting/end returns a fallback summary with transcript."""
        # Create a session
        setup_resp = client.post(
            "/meeting/setup", json=meeting_config, headers=auth_headers
        )
        session_id = setup_resp.json()["session_id"]

        # Make the LLM raise an exception
        mock_llm.generate_summary = AsyncMock(
            side_effect=RuntimeError("LM Studio is down")
        )

        with patch("app.routers.meeting._save_transcript", return_value=None):
            resp = client.post(
                "/meeting/end",
                params={"session_id": session_id},
                headers=auth_headers,
            )
        assert resp.status_code == 200
        data = resp.json()
        assert "Summary generation failed" in data["executive_summary"]
        assert len(data["unresolved"]) > 0
