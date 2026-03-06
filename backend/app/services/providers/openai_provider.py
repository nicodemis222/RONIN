"""OpenAI (and OpenAI-compatible) API provider."""

import asyncio
import logging

import httpx

from app.services.providers.base import BaseLLMProvider

logger = logging.getLogger(__name__)


class OpenAIProvider(BaseLLMProvider):
    """Provider for OpenAI API and any OpenAI-compatible endpoint.

    Works with: OpenAI, Groq, Together AI, Fireworks, Mistral, etc.
    Set a custom base_url for non-OpenAI services.
    """

    # Known context windows per model
    MODEL_CONTEXTS = {
        "gpt-4o": 128_000,
        "gpt-4o-mini": 128_000,
        "gpt-4-turbo": 128_000,
        "gpt-4": 8_192,
        "gpt-3.5-turbo": 16_385,
        # Popular non-OpenAI models on compatible APIs
        "llama-3.1-70b-versatile": 128_000,  # Groq
        "llama-3.1-8b-instant": 128_000,  # Groq
        "mixtral-8x7b-32768": 32_768,  # Groq
    }

    DEFAULT_MODEL = "gpt-4o-mini"

    def __init__(
        self,
        api_key: str,
        base_url: str = "https://api.openai.com/v1",
        model: str | None = None,
    ):
        self.api_key = api_key
        self.base_url = base_url.rstrip("/")
        self.model = model or self.DEFAULT_MODEL
        self.client = httpx.AsyncClient(timeout=120.0)

    @property
    def name(self) -> str:
        return "openai"

    @property
    def is_cloud(self) -> bool:
        return "localhost" not in self.base_url and "127.0.0.1" not in self.base_url

    def supports_thinking_suppression(self) -> bool:
        return False

    def is_available(self) -> bool:
        return bool(self.api_key)

    def is_context_overflow_error(self, error: httpx.HTTPStatusError) -> bool:
        """OpenAI returns 400 with 'context_length_exceeded' for overflow."""
        try:
            body = error.response.json()
            err_code = body.get("error", {}).get("code", "")
            err_msg = body.get("error", {}).get("message", "").lower()
            return (
                error.response.status_code == 400
                and (
                    err_code == "context_length_exceeded"
                    or "maximum context length" in err_msg
                    or "too many tokens" in err_msg
                )
            )
        except Exception:
            return False

    async def detect_context_length(self) -> tuple[int, str]:
        """Return known context window for the configured model."""
        ctx = self.MODEL_CONTEXTS.get(self.model, 128_000)
        logger.info(f"OpenAI model '{self.model}' — context: {ctx:,} tokens")
        return ctx, self.model

    # Retry settings for 429 rate-limit errors
    MAX_RETRIES_429 = 3
    INITIAL_BACKOFF = 2.0  # seconds

    async def chat_completion(
        self, messages: list[dict], temperature: float, max_tokens: int
    ) -> str:
        """Call the OpenAI-compatible chat completions endpoint.

        Automatically retries on 429 (rate limit) errors with exponential
        backoff, respecting the Retry-After header when provided.
        """
        # Filter out Qwen thinking suppression messages
        filtered = [
            m for m in messages
            if not (m["role"] == "assistant" and "<think>" in m.get("content", ""))
        ]

        payload = {
            "model": self.model,
            "messages": filtered,
            "temperature": temperature,
            "max_tokens": max_tokens,
        }

        last_error: httpx.HTTPStatusError | None = None
        for attempt in range(self.MAX_RETRIES_429 + 1):
            try:
                response = await self.client.post(
                    f"{self.base_url}/chat/completions",
                    headers={
                        "Authorization": f"Bearer {self.api_key}",
                        "Content-Type": "application/json",
                    },
                    json=payload,
                )
                response.raise_for_status()
                result = response.json()
                content = result["choices"][0]["message"]["content"]
                logger.info(f"OpenAI response ({len(content)} chars)")
                return content
            except httpx.HTTPStatusError as e:
                if e.response.status_code == 429 and attempt < self.MAX_RETRIES_429:
                    last_error = e
                    # Respect Retry-After header if present, otherwise exponential backoff
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
                logger.error("OpenAI request timed out")
                raise
            except Exception as e:
                logger.error(f"OpenAI request failed: {e}")
                raise

        # All retries exhausted — re-raise the last 429 error
        assert last_error is not None
        raise last_error

    async def close(self):
        await self.client.aclose()
