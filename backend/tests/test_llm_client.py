"""Tests for app/services/llm_client.py — JSON extraction, normalisation, budgets."""

import json

import pytest

from app.services.llm_client import (
    LLMClient,
    _extract_json,
    _normalize_copilot,
    _normalize_summary,
)


# ═══════════════════════════════════════════════════════════════════════════
# _extract_json
# ═══════════════════════════════════════════════════════════════════════════

class TestExtractJson:
    def test_extract_clean_json(self):
        """Plain JSON string is parsed directly."""
        raw = '{"key": "value", "n": 42}'
        assert _extract_json(raw) == {"key": "value", "n": 42}

    def test_extract_with_qwen_thinking_block(self):
        """Qwen <think>...</think> blocks are stripped before parsing."""
        raw = (
            "<think>\nLet me reason about this...\n"
            "The user wants a summary.\n</think>\n"
            '{"executive_summary": "All good"}'
        )
        result = _extract_json(raw)
        assert result == {"executive_summary": "All good"}

    def test_extract_with_markdown_fences(self):
        """Markdown ```json ... ``` fences are stripped."""
        raw = '```json\n{"a": 1}\n```'
        assert _extract_json(raw) == {"a": 1}

    def test_extract_with_preamble_text(self):
        """Preamble text before JSON is ignored."""
        raw = 'Here is the JSON output:\n\n{"result": true}'
        assert _extract_json(raw) == {"result": True}

    def test_extract_no_json_raises(self):
        """When there is no JSON at all, a JSONDecodeError is raised."""
        with pytest.raises(json.JSONDecodeError):
            _extract_json("No JSON here, just plain text.")

    def test_extract_multiple_json_objects(self):
        """When multiple JSON objects are present, the last one is used."""
        raw = (
            'First object: {"ignore": true}\n'
            'Second object: {"keep": "this"}'
        )
        result = _extract_json(raw)
        assert result == {"keep": "this"}


# ═══════════════════════════════════════════════════════════════════════════
# _normalize_copilot
# ═══════════════════════════════════════════════════════════════════════════

class TestNormalizeCopilot:
    def test_normalize_missing_fields_get_defaults(self):
        """Missing top-level fields default to empty lists."""
        data = _normalize_copilot({})
        assert data["suggestions"] == []
        assert data["follow_up_questions"] == []
        assert data["risks"] == []
        assert data["facts_from_notes"] == []

    def test_normalize_alternative_field_names(self):
        """Alternative field names like 'suggested_responses' map to 'suggestions'."""
        data = _normalize_copilot({
            "suggested_responses": [{"tone": "direct", "text": "Hi"}],
            "followup_questions": ["Q1"],
            "warnings": [{"warning": "W1", "context": "C1"}],
            "relevant_facts": [{"fact": "F1", "source": "S1"}],
        })
        assert len(data["suggestions"]) == 1
        assert data["suggestions"][0]["text"] == "Hi"
        assert data["follow_up_questions"] == ["Q1"]
        assert len(data["risks"]) == 1
        assert len(data["facts_from_notes"]) == 1

    def test_normalize_string_suggestions_get_diverse_tones(self):
        """String suggestions are wrapped with diverse tones (diversity enforcement)."""
        data = _normalize_copilot({
            "suggestions": ["Just do it", "Try again"],
        })
        assert len(data["suggestions"]) == 2
        # Diversity enforcement re-labels identical tones
        tones = {s["tone"] for s in data["suggestions"]}
        assert len(tones) == 2  # Two different tones
        for s in data["suggestions"]:
            assert s["tone"] in ("direct", "diplomatic", "analytical", "empathetic")
            assert isinstance(s["text"], str)

    def test_normalize_string_risks_get_context(self):
        """String risks are wrapped with context=''."""
        data = _normalize_copilot({
            "risks": ["Budget overrun", "Timeline slip"],
        })
        assert len(data["risks"]) == 2
        for r in data["risks"]:
            assert r["warning"] in ("Budget overrun", "Timeline slip")
            assert r["context"] == ""

    def test_normalize_string_facts_get_source(self):
        """String facts are wrapped with source='notes'."""
        data = _normalize_copilot({
            "facts_from_notes": ["Revenue was $1M last quarter"],
        })
        assert len(data["facts_from_notes"]) == 1
        assert data["facts_from_notes"][0]["fact"] == "Revenue was $1M last quarter"
        assert data["facts_from_notes"][0]["source"] == "notes"

    def test_normalize_content_key_maps_to_text(self):
        """Suggestion dicts with 'content' key have it mapped to 'text'."""
        data = _normalize_copilot({
            "suggestions": [{"tone": "diplomatic", "content": "Let us reconsider"}],
        })
        assert data["suggestions"][0]["text"] == "Let us reconsider"
        assert "content" not in data["suggestions"][0]

    def test_normalize_tone_aliases(self):
        """Legacy tone names are mapped to current ones."""
        data = _normalize_copilot({
            "suggestions": [
                {"tone": "curious", "text": "What if..."},
                {"tone": "assertive", "text": "We must..."},
                {"tone": "supportive", "text": "I understand..."},
            ],
        })
        assert data["suggestions"][0]["tone"] == "analytical"
        assert data["suggestions"][1]["tone"] == "direct"
        assert data["suggestions"][2]["tone"] == "empathetic"

    def test_normalize_invalid_tone_defaults_to_direct(self):
        """Unknown tone values default to 'direct'."""
        data = _normalize_copilot({
            "suggestions": [{"tone": "sarcastic", "text": "Sure, great idea"}],
        })
        assert data["suggestions"][0]["tone"] == "direct"

    def test_normalize_enforces_tone_diversity(self):
        """When all suggestions have the same tone, they get diverse tones."""
        data = _normalize_copilot({
            "suggestions": [
                {"tone": "direct", "text": "A"},
                {"tone": "direct", "text": "B"},
                {"tone": "direct", "text": "C"},
            ],
        })
        tones = [s["tone"] for s in data["suggestions"]]
        assert len(set(tones)) == 3  # All different
        assert tones[0] == "direct"
        assert tones[1] == "diplomatic"
        assert tones[2] == "analytical"

    def test_normalize_keeps_diverse_tones(self):
        """When tones are already diverse, they're preserved."""
        data = _normalize_copilot({
            "suggestions": [
                {"tone": "direct", "text": "A"},
                {"tone": "diplomatic", "text": "B"},
                {"tone": "empathetic", "text": "C"},
            ],
        })
        assert data["suggestions"][0]["tone"] == "direct"
        assert data["suggestions"][1]["tone"] == "diplomatic"
        assert data["suggestions"][2]["tone"] == "empathetic"


# ═══════════════════════════════════════════════════════════════════════════
# _normalize_summary
# ═══════════════════════════════════════════════════════════════════════════

class TestNormalizeSummary:
    def test_normalize_summary_defaults(self):
        """Missing fields get sensible defaults."""
        data = _normalize_summary({})
        assert data["executive_summary"] == ""
        assert data["decisions"] == []
        assert data["action_items"] == []
        assert data["unresolved"] == []

    def test_normalize_string_decisions(self):
        """String decisions are wrapped into {decision, context} dicts."""
        data = _normalize_summary({
            "decisions": ["We will use React", "Deploy on Friday"],
        })
        assert len(data["decisions"]) == 2
        assert data["decisions"][0]["decision"] == "We will use React"
        assert data["decisions"][0]["context"] == ""

    def test_normalize_action_items_alt_keys(self):
        """Action item dicts with 'task' key have it mapped to 'action'."""
        data = _normalize_summary({
            "action_items": [
                {"task": "Write tests", "assignee": "Alice", "deadline": "Friday"},
            ],
        })
        assert data["action_items"][0]["action"] == "Write tests"
        assert "task" not in data["action_items"][0]

    def test_normalize_string_unresolved(self):
        """Non-string unresolved items are converted to strings."""
        data = _normalize_summary({
            "unresolved": [42, "Need decision on X"],
        })
        assert data["unresolved"] == ["42", "Need decision on X"]


# ═══════════════════════════════════════════════════════════════════════════
# _calibrate_budgets
# ═══════════════════════════════════════════════════════════════════════════

class TestCalibrateBudgets:
    def test_calibrate_4k_context(self):
        """4K context yields small but usable budgets."""
        copilot, summary = LLMClient._calibrate_budgets(4096)
        # 4096 * 0.7 = 2867 tokens -> 11468 chars for summary
        # copilot = summary // 2
        assert summary >= 2000
        assert copilot >= 1000
        assert copilot < summary

    def test_calibrate_8k_context(self):
        """8K context yields proportionally larger budgets."""
        copilot, summary = LLMClient._calibrate_budgets(8192)
        assert summary > 10000
        assert copilot > 5000
        assert copilot < summary

    def test_calibrate_32k_context(self):
        """32K context yields large budgets within caps."""
        copilot, summary = LLMClient._calibrate_budgets(32768)
        assert summary <= 60000
        assert copilot <= 30000
        assert copilot < summary

    def test_calibrate_128k_context(self):
        """128K context is capped at maximum budgets."""
        copilot, summary = LLMClient._calibrate_budgets(131072)
        # Caps: summary <= 60000, copilot <= 30000
        assert summary == 60000
        assert copilot == 30000

    def test_calibrate_tiny_context_floors(self):
        """Very small contexts hit the floor values."""
        copilot, summary = LLMClient._calibrate_budgets(256)
        assert copilot >= 1000  # floor
        assert summary >= 2000  # floor
