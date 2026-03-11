"""LLM client orchestrator.

Delegates API calls to the active provider while keeping shared logic
(JSON extraction, normalization, retry, budget calibration) here.
"""

import json
import logging
import re

import httpx

from app.services.prompt_builder import PromptBuilder
from app.services.providers.base import BaseLLMProvider
from app.schemas.copilot import CopilotResponse
from app.schemas.summary import MeetingSummary

logger = logging.getLogger(__name__)


def _extract_json(text: str) -> dict:
    """Extract JSON from model output.

    Handles:
    - Qwen 3.x thinking blocks: <think>...</think>{json}
    - Markdown code fences: ```json ... ```
    - Preamble/epilogue text around JSON
    """
    text = text.strip()

    # Strip Qwen-style thinking blocks — the actual response comes after </think>
    if "</think>" in text:
        text = text.split("</think>")[-1].strip()

    # Strip markdown code fences
    if text.startswith("```"):
        text = text.split("\n", 1)[1] if "\n" in text else text[3:]
        if text.endswith("```"):
            text = text[:-3]
        text = text.strip()

    # Try direct parse
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

    # Find the last complete JSON object (in case model output multiple)
    # Search from the end to avoid matching partial JSON in preamble
    objects = list(re.finditer(r"\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}", text))
    if objects:
        # Try the last match first (most likely the actual response)
        for match in reversed(objects):
            try:
                return json.loads(match.group())
            except json.JSONDecodeError:
                continue

    # Greedy match as last resort
    match = re.search(r"\{[\s\S]*\}", text)
    if match:
        try:
            return json.loads(match.group())
        except json.JSONDecodeError:
            pass

    raise json.JSONDecodeError("No valid JSON found in response", text[:200], 0)


def _normalize_copilot(data: dict) -> dict:
    """Normalize LLM output to match the CopilotResponse schema.

    Without json_schema enforcement, models may return fields in
    slightly wrong formats (different names, strings instead of objects, etc.).
    """
    # Map alternative field names to expected names
    alt_names = {
        "suggestions": ["suggested_responses", "response_suggestions", "responses"],
        "follow_up_questions": ["followup_questions", "questions", "follow_ups"],
        "risks": ["warnings", "risk_flags", "concerns"],
        "facts_from_notes": ["relevant_facts", "facts", "notes_facts", "note_facts"],
    }
    for canonical, alternatives in alt_names.items():
        if canonical not in data:
            for alt in alternatives:
                if alt in data:
                    data[canonical] = data.pop(alt)
                    break

    # Ensure required keys exist
    data.setdefault("suggestions", [])
    data.setdefault("follow_up_questions", [])
    data.setdefault("risks", [])
    data.setdefault("facts_from_notes", [])

    # Valid tones — map legacy names to current ones
    VALID_TONES = {"direct", "diplomatic", "analytical", "empathetic"}
    TONE_ALIASES = {
        "curious": "analytical",
        "inquisitive": "analytical",
        "assertive": "direct",
        "collaborative": "diplomatic",
        "supportive": "empathetic",
        "compassionate": "empathetic",
    }

    # Normalize suggestions: ensure each has tone + text
    normalized_suggestions = []
    seen_tones: set = set()
    for s in data["suggestions"]:
        if isinstance(s, str):
            normalized_suggestions.append({"tone": "direct", "text": s})
            seen_tones.add("direct")
        elif isinstance(s, dict):
            # Model may use "content", "response", or "message" instead of "text"
            if "text" not in s:
                for alt_key in ("content", "response", "message"):
                    if alt_key in s:
                        s["text"] = s.pop(alt_key)
                        break
            s.setdefault("text", "")

            # Normalize and validate the tone
            raw_tone = s.get("tone", "").lower().strip()
            tone = TONE_ALIASES.get(raw_tone, raw_tone)
            if tone not in VALID_TONES:
                tone = "direct"
            s["tone"] = tone
            seen_tones.add(tone)
            normalized_suggestions.append(s)

    # Enforce diversity: if all suggestions ended up the same tone,
    # re-label them with round-robin tones so the UI shows variety.
    if len(normalized_suggestions) > 1 and len(seen_tones) == 1:
        fallback_tones = ["direct", "diplomatic", "analytical", "empathetic"]
        for i, s in enumerate(normalized_suggestions):
            s["tone"] = fallback_tones[i % len(fallback_tones)]

    data["suggestions"] = normalized_suggestions

    # Normalize risks: model may return strings instead of {warning, context}
    normalized_risks = []
    for r in data["risks"]:
        if isinstance(r, str):
            normalized_risks.append({"warning": r, "context": ""})
        elif isinstance(r, dict):
            r.setdefault("warning", "")
            r.setdefault("context", "")
            normalized_risks.append(r)
    data["risks"] = normalized_risks

    # Normalize facts_from_notes: model may return strings
    normalized_facts = []
    for f in data["facts_from_notes"]:
        if isinstance(f, str):
            normalized_facts.append({"fact": f, "source": "notes"})
        elif isinstance(f, dict):
            f.setdefault("fact", "")
            f.setdefault("source", "notes")
            normalized_facts.append(f)
    data["facts_from_notes"] = normalized_facts

    # Normalize follow_up_questions: ensure list of strings
    data["follow_up_questions"] = [
        q if isinstance(q, str) else str(q)
        for q in data["follow_up_questions"]
    ]

    return data


def _normalize_summary(data: dict) -> dict:
    """Normalize LLM output to match the MeetingSummary schema."""
    data.setdefault("executive_summary", "")
    data.setdefault("decisions", [])
    data.setdefault("action_items", [])
    data.setdefault("unresolved", [])

    # Normalize decisions
    normalized = []
    for d in data["decisions"]:
        if isinstance(d, str):
            normalized.append({"decision": d, "context": ""})
        elif isinstance(d, dict):
            d.setdefault("decision", "")
            d.setdefault("context", "")
            normalized.append(d)
    data["decisions"] = normalized

    # Normalize action_items
    normalized = []
    for a in data["action_items"]:
        if isinstance(a, str):
            normalized.append({"action": a, "assignee": "", "deadline": ""})
        elif isinstance(a, dict):
            # Model may use "task" or "item" instead of "action"
            if "action" not in a:
                for alt_key in ("task", "item", "description"):
                    if alt_key in a:
                        a["action"] = a.pop(alt_key)
                        break
            a.setdefault("action", "")
            a.setdefault("assignee", "")
            a.setdefault("deadline", "")
            normalized.append(a)
    data["action_items"] = normalized

    # Normalize unresolved
    data["unresolved"] = [
        q if isinstance(q, str) else str(q)
        for q in data["unresolved"]
    ]

    return data


class LLMClient:
    """Orchestrator that delegates API calls to a provider.

    Handles: JSON extraction, response normalization, context budget
    calibration, and retry logic on context overflow.
    """

    DEFAULT_COPILOT_BUDGET = 6000
    DEFAULT_SUMMARY_BUDGET = 100000

    def __init__(self, provider: BaseLLMProvider):
        self.provider = provider
        self.prompt_builder = PromptBuilder()
        self._detected_context: int | None = None
        self._copilot_budget: int = self.DEFAULT_COPILOT_BUDGET
        self._summary_budget: int = self.DEFAULT_SUMMARY_BUDGET

    async def detect_context_length(self) -> int:
        """Detect model context length via the provider."""
        n_ctx, model_id = await self.provider.detect_context_length()
        self._detected_context = n_ctx
        self._copilot_budget, self._summary_budget = self._calibrate_budgets(n_ctx)
        logger.info(
            f"Provider '{self.provider.name}' model '{model_id}' — "
            f"context={n_ctx:,}, copilot_budget={self._copilot_budget:,}, "
            f"summary_budget={self._summary_budget:,}"
        )
        return n_ctx

    @staticmethod
    def _calibrate_budgets(n_ctx: int) -> tuple[int, int]:
        """Calculate transcript char budgets from the model's context length.

        Heuristic: ~4 chars per token, reserve ~20% for system prompt + notes,
        ~10% for output tokens. Send as much transcript as possible to avoid
        losing decisions and action items from truncation.
        Copilot budget is ~half of summary (copilot only needs recent context).

        Returns (copilot_budget, summary_budget).
        """
        available_tokens = int(n_ctx * 0.7)
        available_chars = available_tokens * 4

        # For large-context models (128K+ tokens), allow up to 500K chars
        # to capture full meeting transcripts without truncation.
        summary_budget = min(available_chars, 500000)
        copilot_budget = min(summary_budget // 2, 30000)

        copilot_budget = max(copilot_budget, 1000)
        summary_budget = max(summary_budget, 2000)

        return copilot_budget, summary_budget

    async def generate_copilot_response(
        self, transcript_window: str, config, relevant_notes: str
    ) -> CopilotResponse:
        max_chars = self._copilot_budget
        suppress_thinking = self.provider.supports_thinking_suppression()

        for attempt in range(3):
            messages = self.prompt_builder.build_copilot_prompt(
                transcript_window=transcript_window,
                config=config,
                relevant_notes=relevant_notes,
                max_transcript_chars=max_chars,
                suppress_thinking=suppress_thinking,
            )
            try:
                content = await self.provider.chat_completion(
                    messages, temperature=0.7, max_tokens=1200
                )
                data = _extract_json(content)
                data = _normalize_copilot(data)
                result = CopilotResponse(**data)
                logger.info(
                    f"Copilot: {len(result.suggestions)} suggestions, "
                    f"{len(result.follow_up_questions)} questions, "
                    f"{len(result.risks)} risks"
                )
                return result
            except httpx.HTTPStatusError as e:
                if self.provider.is_context_overflow_error(e):
                    max_chars = max_chars // 2
                    logger.warning(
                        f"Copilot prompt exceeds model context — retrying with "
                        f"max_transcript_chars={max_chars} (attempt {attempt + 2}/3)"
                    )
                    continue
                logger.error(f"Copilot generation failed: {e}", exc_info=True)
                status = e.response.status_code if e.response else 0
                if status == 429:
                    raise RuntimeError(
                        "LLM rate limit reached (429). Reduce debounce interval "
                        "or check your API plan."
                    ) from e
                raise RuntimeError(f"LLM API error (HTTP {status})") from e
            except Exception as e:
                logger.error(f"Copilot generation failed: {e}", exc_info=True)
                raise RuntimeError(f"Copilot generation failed: {e}") from e

        logger.error("Copilot generation failed after 3 context-length retries")
        raise RuntimeError(
            "Copilot generation failed — model context too small. "
            "Increase n_ctx in your LLM provider settings."
        )

    async def generate_summary(
        self, transcript: str, config, notes: str
    ) -> MeetingSummary:
        max_chars = self._summary_budget
        suppress_thinking = self.provider.supports_thinking_suppression()

        last_error = None
        for attempt in range(3):
            messages = self.prompt_builder.build_summary_prompt(
                transcript=transcript,
                config=config,
                notes=notes,
                max_transcript_chars=max_chars,
                suppress_thinking=suppress_thinking,
            )
            try:
                content = await self.provider.chat_completion(
                    messages, temperature=0.3, max_tokens=8000
                )
                data = _extract_json(content)
                data = _normalize_summary(data)
                return MeetingSummary(**data)
            except httpx.HTTPStatusError as e:
                if self.provider.is_context_overflow_error(e):
                    max_chars = max_chars // 2
                    logger.warning(
                        f"Transcript exceeds model context — retrying with "
                        f"max_transcript_chars={max_chars} (attempt {attempt + 2}/3)"
                    )
                    last_error = e
                    continue
                logger.error(f"Summary generation failed: {e}", exc_info=True)
                raise RuntimeError(f"Failed to generate summary: {e}")
            except Exception as e:
                logger.error(f"Summary generation failed: {e}", exc_info=True)
                raise RuntimeError(f"Failed to generate summary: {e}")

        raise RuntimeError(
            f"Failed to generate summary after 3 context-length retries: {last_error}"
        )

    async def close(self):
        await self.provider.close()
