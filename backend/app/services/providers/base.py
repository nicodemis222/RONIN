"""Abstract base class for LLM providers."""

from abc import ABC, abstractmethod

import httpx


class BaseLLMProvider(ABC):
    """Interface that all LLM providers must implement.

    The LLMClient orchestrator handles shared logic (JSON extraction,
    normalization, retry with budget halving). Providers handle only
    the API-specific call format and context detection.
    """

    @abstractmethod
    async def chat_completion(
        self, messages: list[dict], temperature: float, max_tokens: int
    ) -> str:
        """Send messages and return the raw text response."""
        ...

    @abstractmethod
    async def detect_context_length(self) -> tuple[int, str]:
        """Return (context_length_tokens, model_id).

        For local providers: query the running server.
        For cloud providers: return known values based on model name.
        """
        ...

    @abstractmethod
    def is_context_overflow_error(self, error: httpx.HTTPStatusError) -> bool:
        """Check whether an HTTP error indicates the prompt exceeded context.

        Each provider signals this differently (LM Studio uses "n_keep",
        Anthropic uses "too long", etc.).
        """
        ...

    @abstractmethod
    def supports_thinking_suppression(self) -> bool:
        """Whether the Qwen <think> prefill should be appended to prompts.

        Only local models (Qwen 3.x) benefit from this. Cloud models
        should not receive it.
        """
        ...

    def is_available(self) -> bool:
        """Whether this provider is configured and ready."""
        return True

    @property
    @abstractmethod
    def name(self) -> str:
        """Human-readable provider name for logging."""
        ...

    @property
    @abstractmethod
    def is_cloud(self) -> bool:
        """Whether transcript data is sent to the cloud."""
        ...

    @abstractmethod
    async def close(self):
        """Clean up HTTP clients and resources."""
        ...
