"""Factory for creating the appropriate LLM provider from settings."""

import logging

from app.config import settings
from app.services.providers.base import BaseLLMProvider

logger = logging.getLogger(__name__)


def create_provider() -> BaseLLMProvider | None:
    """Create the LLM provider based on the LLM_PROVIDER setting.

    Returns None for 'none' (transcription-only mode).
    Raises ValueError if a required API key is missing.
    """
    provider_name = settings.llm_provider.lower().strip()

    if provider_name == "none":
        logger.info("LLM provider: none (transcription-only mode)")
        return None

    elif provider_name == "anthropic":
        if not settings.anthropic_api_key:
            raise ValueError(
                "ANTHROPIC_API_KEY environment variable required for Anthropic provider"
            )
        from app.services.providers.anthropic_provider import AnthropicProvider

        return AnthropicProvider(
            api_key=settings.anthropic_api_key,
            model=settings.llm_model or None,
        )

    elif provider_name == "openai":
        if not settings.openai_api_key:
            raise ValueError(
                "OPENAI_API_KEY environment variable required for OpenAI provider"
            )
        from app.services.providers.openai_provider import OpenAIProvider

        return OpenAIProvider(
            api_key=settings.openai_api_key,
            base_url=settings.openai_base_url,
            model=settings.llm_model or None,
        )

    else:  # "local" (default)
        from app.services.providers.local import LocalProvider

        return LocalProvider(base_url=settings.lm_studio_url)
