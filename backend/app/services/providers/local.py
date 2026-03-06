"""Local LLM provider — LM Studio / Ollama (OpenAI-compatible)."""

import logging

import httpx

from app.services.providers.base import BaseLLMProvider

logger = logging.getLogger(__name__)


class LocalProvider(BaseLLMProvider):
    """Provider for locally-running OpenAI-compatible LLM servers.

    Supports LM Studio, Ollama, and any server that implements the
    OpenAI /v1/chat/completions API.
    """

    def __init__(self, base_url: str = "http://localhost:1234/v1"):
        self.base_url = base_url.rstrip("/")
        self.client = httpx.AsyncClient(timeout=120.0)
        self._model_id: str | None = None

    @property
    def name(self) -> str:
        return "local"

    @property
    def is_cloud(self) -> bool:
        return False

    def supports_thinking_suppression(self) -> bool:
        return True

    def is_available(self) -> bool:
        return True  # Always "available" — fails at call time if server is down

    def is_context_overflow_error(self, error: httpx.HTTPStatusError) -> bool:
        """LM Studio returns 400 with 'n_keep' in the body on context overflow."""
        try:
            body = error.response.text[:500]
            return error.response.status_code == 400 and "n_keep" in body
        except Exception:
            return False

    async def detect_context_length(self) -> tuple[int, str]:
        """Query the local server for the loaded model's context length.

        Strategy 1: LM Studio internal API (/api/v1/models)
        Strategy 2: OpenAI-compatible /v1/models
        Fallback: 4096 tokens
        """
        base = self.base_url.replace("/v1", "")
        n_ctx = None
        max_ctx = None
        model_id = "unknown"

        # ── Strategy 1: LM Studio internal API ────────────────────
        try:
            resp = await self.client.get(f"{base}/api/v1/models", timeout=5.0)
            if resp.status_code == 200:
                data = resp.json()
                for model in data.get("models", []):
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

        # ── Strategy 2: OpenAI-compatible /v1/models ──────────────
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

        # ── Apply result ──────────────────────────────────────────
        if n_ctx:
            n_ctx = int(n_ctx)
            logger.info(f"Detected model '{model_id}' context length: {n_ctx:,} tokens")
            if max_ctx and int(max_ctx) > n_ctx * 4:
                logger.warning(
                    f"Model supports up to {int(max_ctx):,} tokens but n_ctx is only {n_ctx:,}. "
                    f"For 1-hour meetings, increase context length in LM Studio to at least 16,384."
                )
        else:
            n_ctx = 4096
            logger.warning(
                f"Could not detect context length for '{model_id}' — "
                f"assuming {n_ctx:,}. Set n_ctx in LM Studio for best results."
            )

        self._model_id = model_id if model_id != "unknown" else None
        return n_ctx, model_id

    async def chat_completion(
        self, messages: list[dict], temperature: float, max_tokens: int
    ) -> str:
        """Call the local OpenAI-compatible chat completions endpoint."""
        try:
            payload: dict = {
                "messages": messages,
                "temperature": temperature,
                "max_tokens": max_tokens,
            }
            # Include model ID to disambiguate when multiple models are loaded
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
        except httpx.HTTPStatusError:
            raise
        except httpx.TimeoutException:
            logger.error("LLM request timed out")
            raise
        except Exception as e:
            logger.error(f"LLM request failed: {e}")
            raise

    async def close(self):
        await self.client.aclose()
