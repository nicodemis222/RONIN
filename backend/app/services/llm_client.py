import json
import logging
import re

import httpx

from app.config import settings
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
    # Default budgets (overridden by detect_context_length → _calibrate_budgets)
    DEFAULT_COPILOT_BUDGET = 6000
    DEFAULT_SUMMARY_BUDGET = 12000

    def __init__(self, base_url: str = "http://localhost:1234/v1"):
        self.base_url = base_url
        self.client = httpx.AsyncClient(timeout=120.0)
        self.prompt_builder = PromptBuilder()
        self._detected_context: int | None = None
        self._copilot_budget: int = self.DEFAULT_COPILOT_BUDGET
        self._summary_budget: int = self.DEFAULT_SUMMARY_BUDGET
        self._model_id: str | None = None  # Detected LLM model identifier

    async def detect_context_length(self) -> int:
        """Query LM Studio for the loaded model's context length.

        Uses LM Studio's internal API (/api/v1/models) which exposes the
        actual configured context_length and the model's max_context_length.
        Falls back to the OpenAI-compatible /v1/models endpoint, then to
        a conservative default.
        """
        base = self.base_url.replace("/v1", "")  # e.g. http://localhost:1234

        n_ctx = None
        max_ctx = None
        model_id = "unknown"

        # ── Strategy 1: LM Studio internal API (most reliable) ────────
        try:
            resp = await self.client.get(f"{base}/api/v1/models", timeout=5.0)
            if resp.status_code == 200:
                data = resp.json()
                for model in data.get("models", []):
                    # Skip non-LLM models (e.g. embedding models)
                    if model.get("type") and model["type"] != "llm":
                        continue
                    instances = model.get("loaded_instances", [])
                    if instances:
                        model_id = model.get("key", model.get("display_name", "unknown"))
                        config = instances[0].get("config", {})
                        n_ctx = config.get("context_length")
                        max_ctx = model.get("max_context_length")
                        break
        except Exception as e:
            logger.debug(f"LM Studio internal API not available: {e}")

        # ── Strategy 2: OpenAI-compatible /v1/models ──────────────────
        if not n_ctx:
            try:
                resp = await self.client.get(f"{self.base_url}/models", timeout=5.0)
                resp.raise_for_status()
                models = resp.json()
                if models.get("data"):
                    model = models["data"][0]
                    model_id = model.get("id", "unknown")
                    n_ctx = (
                        model.get("context_length")
                        or model.get("max_context_length")
                        or model.get("context_window")
                    )
            except Exception as e:
                logger.debug(f"OpenAI models endpoint failed: {e}")

        # ── Apply result ──────────────────────────────────────────────
        if n_ctx:
            n_ctx = int(n_ctx)
            logger.info(f"Detected model '{model_id}' context length: {n_ctx:,} tokens")

            # If the model supports much more context than configured, log a hint
            if max_ctx and int(max_ctx) > n_ctx * 4:
                logger.warning(
                    f"⚡ Model supports up to {int(max_ctx):,} tokens but n_ctx is only {n_ctx:,}. "
                    f"For 1-hour meetings, increase context length in LM Studio to at least 16,384."
                )
        else:
            n_ctx = 4096
            logger.warning(
                f"Could not detect context length for '{model_id}' — "
                f"assuming {n_ctx:,}. Set n_ctx in LM Studio for best results."
            )

        self._detected_context = n_ctx
        self._model_id = model_id if model_id != "unknown" else None
        self._copilot_budget, self._summary_budget = self._calibrate_budgets(n_ctx)
        logger.info(
            f"Using model '{model_id}' — budget calibrated: "
            f"copilot={self._copilot_budget:,} chars, summary={self._summary_budget:,} chars"
        )
        return n_ctx

    @staticmethod
    def _calibrate_budgets(n_ctx: int) -> tuple[int, int]:
        """Calculate transcript char budgets from the model's context length.

        Heuristic: ~4 chars per token, reserve ~30% for system prompt + notes + output.
        Copilot budget is ~half of summary (copilot only needs recent context).

        Returns (copilot_budget, summary_budget).
        """
        # Available tokens for transcript ≈ 70% of context
        available_tokens = int(n_ctx * 0.7)
        # Convert to chars (~4 chars per token for English)
        available_chars = available_tokens * 4

        # Summary gets the full available budget; copilot gets half
        summary_budget = min(available_chars, 60000)  # Cap at 60K chars
        copilot_budget = min(summary_budget // 2, 30000)  # Cap at 30K chars

        # Floor to prevent tiny budgets
        copilot_budget = max(copilot_budget, 1000)
        summary_budget = max(summary_budget, 2000)

        return copilot_budget, summary_budget

    async def _chat_completion(self, messages: list[dict], temperature: float,
                                max_tokens: int) -> str:
        """Call LM Studio chat completions.

        Uses NO response_format for maximum compatibility — Qwen 3.x models
        use a thinking mode that outputs <think>...</think> before the JSON,
        which is incompatible with json_object/json_schema response formats.
        """
        try:
            payload = {
                "messages": messages,
                "temperature": temperature,
                "max_tokens": max_tokens,
            }
            # Include model ID to disambiguate when multiple models are loaded
            # (e.g. an LLM + an embedding model). Without this, LM Studio
            # returns 400 "Multiple models are loaded".
            if self._model_id:
                payload["model"] = self._model_id
            response = await self.client.post(
                f"{self.base_url}/chat/completions",
                json=payload,
            )
            response.raise_for_status()
            result = response.json()
            content = result["choices"][0]["message"]["content"]
            logger.info(f"LLM response ({len(content)} chars)")
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
        max_chars = self._copilot_budget  # Calibrated from detected context length

        # Retry loop: if the prompt exceeds the model's context,
        # halve the transcript budget and try again.
        for attempt in range(3):
            messages = self.prompt_builder.build_copilot_prompt(
                transcript_window=transcript_window,
                config=config,
                relevant_notes=relevant_notes,
                max_transcript_chars=max_chars,
            )
            try:
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
            except httpx.HTTPStatusError as e:
                body = ""
                try:
                    body = e.response.text[:500]
                except Exception:
                    pass
                if e.response.status_code == 400 and "n_keep" in body:
                    max_chars = max_chars // 2
                    logger.warning(
                        f"Copilot prompt exceeds model context — retrying with "
                        f"max_transcript_chars={max_chars} (attempt {attempt + 2}/3)"
                    )
                    continue
                logger.error(f"Copilot generation failed: {e}", exc_info=True)
                return CopilotResponse()
            except Exception as e:
                logger.error(f"Copilot generation failed: {e}", exc_info=True)
                return CopilotResponse()

        logger.error("Copilot generation failed after 3 context-length retries")
        return CopilotResponse()

    async def generate_summary(
        self, transcript: str, config, notes: str
    ) -> MeetingSummary:
        max_chars = self._summary_budget  # Calibrated from detected context length

        # Retry loop: if the prompt still exceeds the model's context,
        # halve the transcript budget and try again (up to 3 attempts).
        last_error = None
        for attempt in range(3):
            messages = self.prompt_builder.build_summary_prompt(
                transcript=transcript,
                config=config,
                notes=notes,
                max_transcript_chars=max_chars,
            )
            try:
                content = await self._chat_completion(messages, temperature=0.3, max_tokens=2000)
                data = _extract_json(content)
                data = _normalize_summary(data)
                return MeetingSummary(**data)
            except httpx.HTTPStatusError as e:
                body = ""
                try:
                    body = e.response.text[:500]
                except Exception:
                    pass
                # Detect context-length overflow and retry with shorter transcript
                if e.response.status_code == 400 and "n_keep" in body:
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
        await self.client.aclose()
