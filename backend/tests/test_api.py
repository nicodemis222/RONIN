"""Tests for the REST API endpoints in app/routers/meeting.py."""

from unittest.mock import AsyncMock, MagicMock, patch

import pytest


# ── Health endpoint ───────────────────────────────────────────────────────

class TestHealth:
    def test_health_returns_ok(self, client):
        """GET /meeting/health requires no auth and returns {"status": "ok"}."""
        resp = client.get("/meeting/health")
        assert resp.status_code == 200
        assert resp.json() == {"status": "ok"}

    def test_health_detailed_returns_dependencies(self, client):
        """GET /meeting/health?details=true returns dependency info."""
        resp = client.get("/meeting/health", params={"details": "true"})
        assert resp.status_code == 200
        data = resp.json()
        assert "status" in data
        assert "dependencies" in data
        deps = data["dependencies"]
        assert "whisper" in deps
        assert "llm" in deps
        assert "meeting" in deps
        # Whisper should have model name and status
        assert "model" in deps["whisper"]
        assert deps["whisper"]["status"] in ("loaded", "available")
        # Meeting should show active state
        assert "active" in deps["meeting"]


# ── Graceful Shutdown ─────────────────────────────────────────────────────

class TestGracefulShutdown:
    def test_shutdown_no_active_session(self, client, auth_headers):
        """POST /meeting/shutdown with no active session returns cleanly."""
        resp = client.post("/meeting/shutdown", headers=auth_headers)
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] == "shutting_down"
        assert data["transcript_saved"] is False
        assert data["segments_saved"] == 0

    def test_shutdown_saves_active_transcript(
        self, client, auth_headers, meeting_config
    ):
        """POST /meeting/shutdown saves transcript from active session."""
        # Set up a meeting
        setup_resp = client.post(
            "/meeting/setup", json=meeting_config, headers=auth_headers
        )
        assert setup_resp.status_code == 200

        with patch("app.routers.meeting._save_transcript", return_value="/tmp/test.md"):
            resp = client.post("/meeting/shutdown", headers=auth_headers)
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] == "shutting_down"

    def test_shutdown_unauthorized(self, client):
        """POST /meeting/shutdown without auth returns 401."""
        resp = client.post("/meeting/shutdown")
        assert resp.status_code == 401


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


# ── Notes validation at API level ────────────────────────────────────────

class TestNotesValidation:
    def test_setup_with_notes(self, client, auth_headers):
        """POST /meeting/setup with valid notes succeeds and notes are stored."""
        config = {
            "title": "Design Review",
            "goal": "Review mockups",
            "notes": [
                {"name": "design.md", "content": "Use rounded corners everywhere"},
                {"name": "colors.txt", "content": "Primary: #00FF41, Background: #0D0208"},
            ],
        }
        resp = client.post("/meeting/setup", json=config, headers=auth_headers)
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] == "ready"
        assert "session_id" in data

    def test_setup_empty_notes_list(self, client, auth_headers):
        """POST /meeting/setup with an empty notes list is perfectly valid."""
        config = {
            "title": "Quick Sync",
            "goal": "Status updates",
            "notes": [],
        }
        resp = client.post("/meeting/setup", json=config, headers=auth_headers)
        assert resp.status_code == 200

    def test_setup_no_notes_field(self, client, auth_headers):
        """POST /meeting/setup without the notes field at all defaults to []."""
        config = {"title": "Quick Sync", "goal": "Status updates"}
        resp = client.post("/meeting/setup", json=config, headers=auth_headers)
        assert resp.status_code == 200

    def test_setup_title_too_long(self, client, auth_headers):
        """POST /meeting/setup rejects title exceeding 200 characters."""
        config = {
            "title": "A" * 201,
            "goal": "Review",
            "notes": [],
        }
        resp = client.post("/meeting/setup", json=config, headers=auth_headers)
        assert resp.status_code == 422

    def test_setup_goal_too_long(self, client, auth_headers):
        """POST /meeting/setup rejects goal exceeding 1000 characters."""
        config = {
            "title": "Planning",
            "goal": "G" * 1001,
            "notes": [],
        }
        resp = client.post("/meeting/setup", json=config, headers=auth_headers)
        assert resp.status_code == 422

    def test_setup_constraints_too_long(self, client, auth_headers):
        """POST /meeting/setup rejects constraints exceeding 2000 characters."""
        config = {
            "title": "Planning",
            "goal": "Decide scope",
            "constraints": "C" * 2001,
            "notes": [],
        }
        resp = client.post("/meeting/setup", json=config, headers=auth_headers)
        assert resp.status_code == 422

    def test_setup_too_many_notes(self, client, auth_headers):
        """POST /meeting/setup rejects more than 20 notes."""
        config = {
            "title": "Overloaded",
            "goal": "Too much context",
            "notes": [
                {"name": f"note_{i}.md", "content": f"Content {i}"}
                for i in range(21)
            ],
        }
        resp = client.post("/meeting/setup", json=config, headers=auth_headers)
        assert resp.status_code == 422

    def test_setup_note_name_too_long(self, client, auth_headers):
        """POST /meeting/setup rejects a note whose name exceeds 200 characters."""
        config = {
            "title": "Design Review",
            "goal": "Review",
            "notes": [
                {"name": "x" * 201, "content": "Some content"},
            ],
        }
        resp = client.post("/meeting/setup", json=config, headers=auth_headers)
        assert resp.status_code == 422

    def test_setup_note_missing_name(self, client, auth_headers):
        """POST /meeting/setup rejects a note without a name field."""
        config = {
            "title": "Design Review",
            "goal": "Review",
            "notes": [{"content": "Some content"}],
        }
        resp = client.post("/meeting/setup", json=config, headers=auth_headers)
        assert resp.status_code == 422

    def test_setup_note_missing_content(self, client, auth_headers):
        """POST /meeting/setup rejects a note without a content field."""
        config = {
            "title": "Design Review",
            "goal": "Review",
            "notes": [{"name": "readme.md"}],
        }
        resp = client.post("/meeting/setup", json=config, headers=auth_headers)
        assert resp.status_code == 422

    def test_setup_exactly_20_notes_ok(self, client, auth_headers):
        """POST /meeting/setup accepts exactly 20 notes (the boundary)."""
        config = {
            "title": "Max Notes",
            "goal": "Boundary test",
            "notes": [
                {"name": f"note_{i}.md", "content": f"Content for note {i}"}
                for i in range(20)
            ],
        }
        resp = client.post("/meeting/setup", json=config, headers=auth_headers)
        assert resp.status_code == 200

    def test_setup_title_exactly_200_chars_ok(self, client, auth_headers):
        """POST /meeting/setup accepts a title at exactly 200 characters."""
        config = {
            "title": "T" * 200,
            "goal": "Boundary test",
            "notes": [],
        }
        resp = client.post("/meeting/setup", json=config, headers=auth_headers)
        assert resp.status_code == 200
