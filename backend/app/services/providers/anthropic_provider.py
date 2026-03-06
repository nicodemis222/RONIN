"""Anthropic Claude API provider."""

import asyncio
import logging

import httpx

from app.services.providers.base import BaseLLMProvider

logger = logging.getLogger(__name__)


class AnthropicProvider(BaseLLMProvider):
    """Provider for the Anthropic Messages API.

    Uses httpx directly (no SDK dependency) to keep the packaged app small.
    Converts OpenAI-format messages to Anthropic format automatically.
    """

    # Known context windows per model
    MODEL_CONTEXTS = {
        # Claude 4 family
        "claude-sonnet-4-20250514": 200_000,
        "claude-opus-4-20250514": 200_000,
        # Claude 3.5 family
        "claude-3-5-sonnet-20241022": 200_000,
        "claude-3-5-haiku-20241022": 200_000,
        # Claude 3 family
        "claude-3-opus-20240229": 200_000,
        "claude-3-sonnet-20240229": 200_000,
        "claude-3-haiku-20240307": 200_000,
    }

    DEFAULT_MODEL = "claude-sonnet-4-20250514"

    def __init__(self, api_key: str, model: str | None = None):
        self.api_key = api_key
        self.model = model or self.DEFAULT_MODEL
        self.client = httpx.AsyncClient(timeout=120.0)

    @property
    def name(self) -> str:
        return "anthropic"

    @property
    def is_cloud(self) -> bool:
        return True

    def supports_thinking_suppression(self) -> bool:
        return False

    def is_available(self) -> bool:
        return bool(self.api_key)

    def is_context_overflow_error(self, error: httpx.HTTPStatusError) -> bool:
        """Anthropic returns 400 with 'too long' for context overflow."""
        try:
            body = error.response.json()
            err_msg = body.get("error", {}).get("message", "").lower()
            err_type = body.get("error", {}).get("type", "")
            return (
                error.response.status_code == 400
                and err_type == "invalid_request_error"
                and ("too long" in err_msg or "too many tokens" in err_msg)
            )
        except Exception:
            return False

    async def detect_context_length(self) -> tuple[int, str]:
        """Return known context window for the configured model."""
        ctx = self.MODEL_CONTEXTS.get(self.model, 200_000)
        logger.info(f"Anthropic model '{self.model}' — context: {ctx:,} tokens")
        return ctx, self.model

    # Retry settings for 429 rate-limit errors
    MAX_RETRIES_429 = 3
    INITIAL_BACKOFF = 2.0  # seconds

    async def chat_completion(
        self, messages: list[dict], temperature: float, max_tokens: int
    ) -> str:
        """Call the Anthropic Messages API.

        Converts OpenAI-format messages (system/user/assistant roles)
        to Anthropic format (system as top-level param, messages list).
        Automatically retries on 429 (rate limit) errors with exponential
        backoff, respecting the Retry-After header when provided.
        """
        system_content = ""
        api_messages = []

        for msg in messages:
            role = msg["role"]
            content = msg.get("content", "")

            if role == "system":
                system_content = content
            elif role == "assistant" and "<think>" in content:
                # Skip Qwen thinking suppression — not applicable to Claude
                continue
            else:
                api_messages.append({"role": role, "content": content})

        payload: dict = {
            "model": self.model,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "messages": api_messages,
        }
        if system_content:
            payload["system"] = system_content

        last_error: httpx.HTTPStatusError | None = None
        for attempt in range(self.MAX_RETRIES_429 + 1):
            try:
                response = await self.client.post(
                    "https://api.anthropic.com/v1/messages",
                    headers={
                        "x-api-key": self.api_key,
                        "anthropic-version": "2023-06-01",
                        "content-type": "application/json",
                    },
                    json=payload,
                )
                response.raise_for_status()
                result = response.json()

                # Anthropic returns content as a list of content blocks
                text = "".join(
                    block["text"]
                    for block in result.get("content", [])
                    if block.get("type") == "text"
                )
                logger.info(f"Anthropic response ({len(text)} chars)")
                return text
            except httpx.HTTPStatusError as e:
                if e.response.status_code == 429 and attempt < self.MAX_RETRIES_429:
                    last_error = e
                    retry_after = e.response.headers.get("retry-after")
                    if retry_after:
                        try:
                            wait = min(float(retry_after), 60.0)
                        except ValueError:
                            wait = self.INITIAL_BACKOFF * (2 ** attempt)
                    else:
                        wait = self.INITIAL_BACKOFF * (2 ** attempt)
                    logger.warning(
                        f"Rate limited (429) — retrying in {wait:.1f}s "
                        f"(attempt {attempt + 1}/{self.MAX_RETRIES_429})"
                    )
                    await asyncio.sleep(wait)
                    continue
                raise
            except httpx.TimeoutException:
                logger.error("Anthropic request timed out")
                raise
            except Exception as e:
                logger.error(f"Anthropic request failed: {e}")
                raise

        # All retries exhausted — re-raise the last 429 error
        assert last_error is not None
        raise last_error

    async def close(self):
        await self.client.aclose()
