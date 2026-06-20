"""Provider-agnostic AI gateway.

Supports three adapter families selected by the AI_ADAPTER env var:

  openai_compat  — OpenAI, Groq, OpenRouter, Together, Fireworks, DeepSeek,
                   or any custom endpoint with an OpenAI-compatible API.
  anthropic      — Anthropic Messages API.
  gemini         — Google Gemini (generativelanguage.googleapis.com).

The public interface is call_llm(), whose signature is unchanged from the
original Groq-only implementation.  The router (gateway.py) is unaffected.
"""

import json
import logging
import time
from collections.abc import AsyncGenerator
from typing import Any

import httpx

from app.config import settings

logger = logging.getLogger(__name__)

_TIMEOUT = 120.0
_MAX_TOKENS = 4096

# ── Default URLs for OpenAI-compatible providers ────────────────────────
# Used when AI_API_URL is empty.  Add new providers here — one line each.
_OPENAI_COMPAT_URLS: dict[str, str] = {
    "groq": "https://api.groq.com/openai/v1/chat/completions",
    "openai": "https://api.openai.com/v1/chat/completions",
    "openrouter": "https://openrouter.ai/api/v1/chat/completions",
    "together": "https://api.together.xyz/v1/chat/completions",
    "fireworks": "https://api.fireworks.ai/inference/v1/chat/completions",
    "deepseek": "https://api.deepseek.com/v1/chat/completions",
}

_ANTHROPIC_URL = "https://api.anthropic.com/v1/messages"
_GEMINI_URL_TEMPLATE = (
    "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
)


class GatewayError(Exception):
    """Raised when the LLM API call fails."""

    def __init__(self, message: str, error_type: str) -> None:
        super().__init__(message)
        self.error_type = error_type


# ── Resolve effective config ────────────────────────────────────────────

def _resolve_api_key() -> str:
    """Return the configured API key, with legacy GROQ_API_KEY fallback."""
    key = settings.AI_API_KEY or settings.GROQ_API_KEY
    if not key:
        raise GatewayError("AI service is not configured", error_type="config_error")
    return key


def _resolve_api_url(adapter: str, model: str) -> str:
    """Return the API endpoint URL for the given adapter."""
    if settings.AI_API_URL:
        return settings.AI_API_URL

    if adapter == "openai_compat":
        # Try to match a known provider name from AI_ADAPTER.
        for name, url in _OPENAI_COMPAT_URLS.items():
            if name == settings.AI_ADAPTER:
                return url
        # If AI_ADAPTER is literally "openai_compat" with no further hint,
        # the user MUST set AI_API_URL.
        raise GatewayError(
            f"AI_API_URL is required when AI_ADAPTER is 'openai_compat' "
            f"and no known provider name is set. "
            f"Known providers: {', '.join(_OPENAI_COMPAT_URLS)}",
            error_type="config_error",
        )
    elif adapter == "anthropic":
        return _ANTHROPIC_URL
    elif adapter == "gemini":
        return _GEMINI_URL_TEMPLATE.format(model=model)
    else:
        raise GatewayError(
            f"Unknown AI_ADAPTER: '{adapter}'. "
            f"Valid values: openai_compat, anthropic, gemini",
            error_type="config_error",
        )


# ── Adapter: OpenAI-compatible ──────────────────────────────────────────

async def _call_openai_compat(
    messages: list[dict[str, str]],
    system_prompt: str | None,
    api_key: str,
    model: str,
    api_url: str,
) -> tuple[str, dict[str, int | None]]:
    api_messages: list[dict[str, str]] = []
    if system_prompt:
        api_messages.append({"role": "system", "content": system_prompt})
    api_messages.extend(messages)

    payload: dict[str, Any] = {
        "model": model,
        "max_tokens": _MAX_TOKENS,
        "messages": api_messages,
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }

    data = await _http_post(api_url, headers=headers, payload=payload)

    choices = data.get("choices", [])
    if not choices:
        raise GatewayError("AI service returned an empty response", error_type="empty_response")

    content = choices[0].get("message", {}).get("content")
    if not content:
        raise GatewayError("AI service returned an empty response", error_type="empty_response")

    usage = data.get("usage", {})
    token_usage = {
        "prompt_tokens": usage.get("prompt_tokens"),
        "completion_tokens": usage.get("completion_tokens"),
        "total_tokens": usage.get("total_tokens"),
    }

    return content, token_usage


# ── Adapter: Anthropic ──────────────────────────────────────────────────

async def _call_anthropic(
    messages: list[dict[str, str]],
    system_prompt: str | None,
    api_key: str,
    model: str,
    api_url: str,
) -> tuple[str, dict[str, int | None]]:
    payload: dict[str, Any] = {
        "model": model,
        "max_tokens": _MAX_TOKENS,
        "messages": messages,
    }
    if system_prompt:
        payload["system"] = system_prompt

    headers = {
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
    }

    data = await _http_post(api_url, headers=headers, payload=payload)

    content_blocks = data.get("content", [])
    if not content_blocks:
        raise GatewayError("AI service returned an empty response", error_type="empty_response")

    text = content_blocks[0].get("text")
    if not text:
        raise GatewayError("AI service returned an empty response", error_type="empty_response")

    usage = data.get("usage", {})
    token_usage = {
        "prompt_tokens": usage.get("input_tokens"),
        "completion_tokens": usage.get("output_tokens"),
        "total_tokens": None,  # Anthropic does not provide total; computed below.
    }
    if token_usage["prompt_tokens"] is not None and token_usage["completion_tokens"] is not None:
        token_usage["total_tokens"] = token_usage["prompt_tokens"] + token_usage["completion_tokens"]

    return text, token_usage


# ── Adapter: Gemini ─────────────────────────────────────────────────────

def _gemini_role(role: str) -> str:
    """Map standard roles to Gemini roles."""
    return "model" if role == "assistant" else "user"


async def _call_gemini(
    messages: list[dict[str, str]],
    system_prompt: str | None,
    api_key: str,
    model: str,
    api_url: str,
) -> tuple[str, dict[str, int | None]]:
    payload: dict[str, Any] = {
        "contents": [
            {"role": _gemini_role(m["role"]), "parts": [{"text": m["content"]}]}
            for m in messages
        ],
        "generationConfig": {"maxOutputTokens": _MAX_TOKENS},
    }
    if system_prompt:
        payload["system_instruction"] = {"parts": [{"text": system_prompt}]}

    # Gemini uses API key as a query parameter.
    url = f"{api_url}?key={api_key}"
    headers = {"Content-Type": "application/json"}

    data = await _http_post(url, headers=headers, payload=payload)

    candidates = data.get("candidates", [])
    if not candidates:
        raise GatewayError("AI service returned an empty response", error_type="empty_response")

    parts = candidates[0].get("content", {}).get("parts", [])
    if not parts or not parts[0].get("text"):
        raise GatewayError("AI service returned an empty response", error_type="empty_response")

    usage_meta = data.get("usageMetadata", {})
    token_usage = {
        "prompt_tokens": usage_meta.get("promptTokenCount"),
        "completion_tokens": usage_meta.get("candidatesTokenCount"),
        "total_tokens": usage_meta.get("totalTokenCount"),
    }

    return parts[0]["text"], token_usage


# ── Shared HTTP transport ───────────────────────────────────────────────

async def _http_post(url: str, *, headers: dict[str, str], payload: dict[str, Any]) -> dict:
    """POST JSON to the provider and return the parsed response.

    Maps provider HTTP errors to GatewayError with a classified error_type.
    """
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        try:
            response = await client.post(url, json=payload, headers=headers)
        except httpx.TimeoutException:
            logger.error("AI API timeout after %.0fs", _TIMEOUT)
            raise GatewayError("Request timed out", error_type="timeout") from None
        except httpx.HTTPError as exc:
            logger.error("AI API network error: %s", exc)
            raise GatewayError(
                "Failed to reach AI service", error_type="network_error"
            ) from exc

    if response.status_code != 200:
        error_type = "api_error"
        if response.status_code == 401:
            error_type = "auth_error"
        elif response.status_code == 429:
            error_type = "rate_limit"
        elif response.status_code >= 500:
            error_type = "server_error"

        logger.error(
            "AI API error: status=%d type=%s body=%s",
            response.status_code,
            error_type,
            response.text[:500],
        )
        raise GatewayError("AI service returned an error", error_type=error_type)

    return response.json()


# ── Adapter dispatch ────────────────────────────────────────────────────

_ADAPTERS = {
    "openai_compat": _call_openai_compat,
    "anthropic": _call_anthropic,
    "gemini": _call_gemini,
}


def _resolve_adapter(adapter_name: str):
    """Return the adapter function for the given AI_ADAPTER value.

    Also handles the case where AI_ADAPTER is set to a known provider
    name (e.g. "groq", "openai") instead of the adapter family.
    """
    if adapter_name in _ADAPTERS:
        return adapter_name, _ADAPTERS[adapter_name]

    # If the user set AI_ADAPTER to a known OpenAI-compatible provider name,
    # treat it as openai_compat.
    if adapter_name in _OPENAI_COMPAT_URLS:
        return "openai_compat", _ADAPTERS["openai_compat"]

    raise GatewayError(
        f"Unknown AI_ADAPTER: '{adapter_name}'. "
        f"Valid values: {', '.join(_ADAPTERS)} or {', '.join(_OPENAI_COMPAT_URLS)}",
        error_type="config_error",
    )


# ── Public interface ───────────────────────────────────────────────────

async def call_llm(
    messages: list[dict[str, str]],
    system_prompt: str | None = None,
) -> tuple[str, int, dict[str, int | None]]:
    """Call the configured AI provider.

    Returns (content, latency_ms, token_usage).  Raises GatewayError on failure.

    ``token_usage`` contains provider-reported token counts with normalized keys:
    ``prompt_tokens``, ``completion_tokens``, ``total_tokens``.
    Values are ``None`` when the provider does not report them.
    """
    api_key = _resolve_api_key()
    model = settings.AI_MODEL
    adapter_name, adapter_fn = _resolve_adapter(settings.AI_ADAPTER)
    api_url = _resolve_api_url(adapter_name, model)

    total_chars = sum(len(m["content"]) for m in messages)
    if system_prompt:
        total_chars += len(system_prompt)
    logger.info(
        "AI request: adapter=%s model=%s url=%s messages=%d total_chars=%d",
        settings.AI_ADAPTER,
        model,
        api_url.split("?")[0],  # strip API key from Gemini URLs in logs
        len(messages),
        total_chars,
    )

    start = time.monotonic()
    content, token_usage = await adapter_fn(messages, system_prompt, api_key, model, api_url)
    latency_ms = int((time.monotonic() - start) * 1000)

    logger.info(
        "AI success: latency=%dms content_length=%d prompt_tokens=%s completion_tokens=%s total_tokens=%s",
        latency_ms,
        len(content),
        token_usage.get("prompt_tokens"),
        token_usage.get("completion_tokens"),
        token_usage.get("total_tokens"),
    )

    # Attach prompt character count for analytics persistence.
    token_usage["prompt_character_count"] = total_chars

    return content, latency_ms, token_usage


# ── Streaming: Anthropic SSE adapter ──────────────────────────────────

async def _stream_anthropic(
    messages: list[dict[str, str]],
    system_prompt: str | None,
    api_key: str,
    model: str,
    api_url: str,
) -> AsyncGenerator[tuple[str, Any], None]:
    """Stream tokens from the Anthropic Messages API.

    Yields tuples of (event_type, data):
      ("token", "text chunk")      — a content delta
      ("done", {token_usage dict}) — final usage after stream ends

    Uses Anthropic's streaming mode (``"stream": true``). Parses SSE
    events and translates them into Decode's internal event format.
    """
    payload: dict[str, Any] = {
        "model": model,
        "max_tokens": _MAX_TOKENS,
        "messages": messages,
        "stream": True,
    }
    if system_prompt:
        payload["system"] = system_prompt

    headers = {
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
    }

    token_usage: dict[str, int | None] = {
        "prompt_tokens": None,
        "completion_tokens": None,
        "total_tokens": None,
    }

    # ── DIAG: Anthropic streaming diagnostics ──
    _diag_request_start = time.monotonic()
    _diag_first_chunk_time = None
    _diag_chunk_count = 0
    _diag_total_chunk_bytes = 0

    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        try:
            async with client.stream("POST", api_url, json=payload, headers=headers) as response:
                if response.status_code != 200:
                    # Read the error body for logging before raising.
                    await response.aread()
                    error_type = "api_error"
                    if response.status_code == 401:
                        error_type = "auth_error"
                    elif response.status_code == 429:
                        error_type = "rate_limit"
                    elif response.status_code >= 500:
                        error_type = "server_error"
                    logger.error(
                        "AI API streaming error: status=%d type=%s body=%s",
                        response.status_code, error_type, response.text[:500],
                    )
                    raise GatewayError("AI service returned an error", error_type=error_type)

                # Parse Anthropic SSE events line by line.
                event_type = ""
                async for raw_line in response.aiter_lines():
                    line = raw_line.strip()

                    if line.startswith("event: "):
                        event_type = line[7:]
                        continue

                    if not line.startswith("data: "):
                        continue

                    data = json.loads(line[6:])

                    if event_type == "message_start":
                        # Extract input token count from the initial message.
                        usage = data.get("message", {}).get("usage", {})
                        token_usage["prompt_tokens"] = usage.get("input_tokens")

                    elif event_type == "content_block_delta":
                        delta = data.get("delta", {})
                        text = delta.get("text", "")
                        if text:
                            # ── DIAG: track Anthropic chunks ──
                            _diag_chunk_count += 1
                            _diag_total_chunk_bytes += len(text)
                            if _diag_first_chunk_time is None:
                                _diag_first_chunk_time = time.monotonic()
                                logger.info(
                                    "DIAG_ANTHROPIC first_chunk_ms=%.0f",
                                    (_diag_first_chunk_time - _diag_request_start) * 1000,
                                )
                            yield ("token", text)

                    elif event_type == "message_delta":
                        # Final event — contains output token count.
                        usage = data.get("usage", {})
                        token_usage["completion_tokens"] = usage.get("output_tokens")
                        if token_usage["prompt_tokens"] is not None and token_usage["completion_tokens"] is not None:
                            token_usage["total_tokens"] = token_usage["prompt_tokens"] + token_usage["completion_tokens"]

                    elif event_type == "error":
                        error_msg = data.get("error", {}).get("message", "Unknown streaming error")
                        raise GatewayError(error_msg, error_type="stream_error")

        except httpx.TimeoutException:
            logger.error("AI API streaming timeout after %.0fs", _TIMEOUT)
            raise GatewayError("Request timed out", error_type="timeout") from None
        except httpx.HTTPError as exc:
            logger.error("AI API streaming network error: %s", exc)
            raise GatewayError("Failed to reach AI service", error_type="network_error") from exc

    # ── DIAG: summary ──
    _diag_elapsed = (time.monotonic() - _diag_request_start) * 1000
    _diag_avg_chunk = (_diag_total_chunk_bytes / _diag_chunk_count) if _diag_chunk_count > 0 else 0
    logger.info(
        "DIAG_ANTHROPIC total_ms=%.0f chunks=%d total_bytes=%d avg_chunk_bytes=%.1f",
        _diag_elapsed, _diag_chunk_count, _diag_total_chunk_bytes, _diag_avg_chunk,
    )

    yield ("done", token_usage)


# ── Streaming adapters registry ───────────────────────────────────────

_STREAM_ADAPTERS: dict[str, Any] = {
    "anthropic": _stream_anthropic,
}


# ── Streaming public interface ────────────────────────────────────────

async def stream_llm(
    messages: list[dict[str, str]],
    system_prompt: str | None = None,
) -> AsyncGenerator[tuple[str, Any], None]:
    """Stream tokens from the configured AI provider.

    Yields tuples of (event_type, data):
      ("token", "text")           — a content chunk
      ("done", {token_usage})     — final usage stats

    If the current adapter does not support streaming, falls back to
    ``call_llm()`` and yields the complete response as a single token
    followed by done.

    Raises GatewayError on failure (before or during streaming).
    """
    api_key = _resolve_api_key()
    model = settings.AI_MODEL
    adapter_name, _ = _resolve_adapter(settings.AI_ADAPTER)
    api_url = _resolve_api_url(adapter_name, model)

    total_chars = sum(len(m["content"]) for m in messages)
    if system_prompt:
        total_chars += len(system_prompt)

    logger.info(
        "AI stream request: adapter=%s model=%s messages=%d total_chars=%d",
        settings.AI_ADAPTER, model, len(messages), total_chars,
    )

    stream_fn = _STREAM_ADAPTERS.get(adapter_name)

    if stream_fn is not None:
        # True streaming path.
        async for event_type, data in stream_fn(messages, system_prompt, api_key, model, api_url):
            if event_type == "done" and isinstance(data, dict):
                data["prompt_character_count"] = total_chars
            yield (event_type, data)
    else:
        # Fallback: non-streaming adapter — yield complete response as one token.
        content, _latency_ms, token_usage = await call_llm(messages, system_prompt)
        yield ("token", content)
        yield ("done", token_usage)
