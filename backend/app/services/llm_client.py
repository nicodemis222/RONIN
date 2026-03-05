import json
import logging
import re

import httpx

from app.services.prompt_builder import PromptBuilder
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

    # Normalize suggestions: ensure each has tone + text
    normalized_suggestions = []
    for s in data["suggestions"]:
        if isinstance(s, str):
            normalized_suggestions.append({"tone": "direct", "text": s})
        elif isinstance(s, dict):
            # Model may use "content", "response", or "message" instead of "text"
            if "text" not in s:
                for alt_key in ("content", "response", "message"):
                    if alt_key in s:
                        s["text"] = s.pop(alt_key)
                        break
            s.setdefault("tone", "direct")
            s.setdefault("text", "")
            normalized_suggestions.append(s)
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
    def __init__(self, base_url: str = "http://localhost:1234/v1"):
        self.base_url = base_url
        self.client = httpx.AsyncClient(timeout=120.0)
        self.prompt_builder = PromptBuilder()

    async def _chat_completion(self, messages: list[dict], temperature: float,
                                max_tokens: int) -> str:
        """Call LM Studio chat completions.

        Uses NO response_format for maximum compatibility — Qwen 3.x models
        use a thinking mode that outputs <think>...</think> before the JSON,
        which is incompatible with json_object/json_schema response formats.
        """
        try:
            response = await self.client.post(
                f"{self.base_url}/chat/completions",
                json={
                    "messages": messages,
                    "temperature": temperature,
                    "max_tokens": max_tokens,
                },
            )
            response.raise_for_status()
            result = response.json()
            content = result["choices"][0]["message"]["content"]
            logger.info(f"LLM response ({len(content)} chars)")
            logger.debug(f"LLM raw: {content[:300]}...")
            return content
        except httpx.HTTPStatusError as e:
            body = ""
            try:
                body = e.response.text[:500]
            except Exception:
                pass
            logger.error(f"LLM HTTP error {e.response.status_code}: {body}")
            raise
        except httpx.TimeoutException:
            logger.error("LLM request timed out")
            raise
        except Exception as e:
            logger.error(f"LLM request failed: {e}")
            raise

    async def generate_copilot_response(
        self, transcript_window: str, config, relevant_notes: str
    ) -> CopilotResponse:
        messages = self.prompt_builder.build_copilot_prompt(
            transcript_window=transcript_window,
            config=config,
            relevant_notes=relevant_notes,
        )

        try:
            # 1200 tokens: thinking is suppressed via assistant prefix,
            # so all tokens go to the actual JSON response
            content = await self._chat_completion(messages, temperature=0.7, max_tokens=1200)
            data = _extract_json(content)
            data = _normalize_copilot(data)
            result = CopilotResponse(**data)
            logger.info(
                f"Copilot: {len(result.suggestions)} suggestions, "
                f"{len(result.follow_up_questions)} questions, "
                f"{len(result.risks)} risks"
            )
            return result
        except Exception as e:
            logger.error(f"Copilot generation failed: {e}", exc_info=True)
            return CopilotResponse()

    async def generate_summary(
        self, transcript: str, config, notes: str
    ) -> MeetingSummary:
        messages = self.prompt_builder.build_summary_prompt(
            transcript=transcript,
            config=config,
            notes=notes,
        )

        try:
            # 2000 tokens: thinking is suppressed via assistant prefix
            content = await self._chat_completion(messages, temperature=0.3, max_tokens=2000)
            data = _extract_json(content)
            data = _normalize_summary(data)
            return MeetingSummary(**data)
        except Exception as e:
            logger.error(f"Summary generation failed: {e}", exc_info=True)
            raise RuntimeError(f"Failed to generate summary: {e}")

    async def close(self):
        await self.client.aclose()
