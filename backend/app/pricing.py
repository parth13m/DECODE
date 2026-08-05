"""Model pricing — single source of truth for AI cost estimation.

All cost estimation in the backend imports from here. When a new model
is added, update this one file.

Rates are per million tokens (input_rate, output_rate) in USD.
"""

MODEL_PRICING_PER_MTOK: dict[str, tuple[float, float]] = {
    # Anthropic — used for explanation and vision
    "claude-haiku-4-5-20251001": (0.80, 4.00),
    # Groq — used for KGR background knowledge generation
    "llama-3.3-70b-versatile": (0.59, 0.79),
    # Groq vision — used when VISION_PROVIDER=groq
    "qwen/qwen3.6-27b": (0.20, 0.20),
    # Gemini — available via AI_ADAPTER=gemini (not currently active)
    "gemini-pro": (0.50, 1.50),
}


def estimate_cost(
    model: str | None,
    prompt_tokens: int | None,
    completion_tokens: int | None,
) -> float | None:
    """Estimate cost in USD for a single request.

    Returns None if model is unknown or token counts are missing.
    """
    if not model or not prompt_tokens or not completion_tokens:
        return None
    pricing = MODEL_PRICING_PER_MTOK.get(model)
    if pricing is None:
        return None
    input_rate, output_rate = pricing
    return round(
        (prompt_tokens * input_rate + completion_tokens * output_rate) / 1_000_000,
        6,
    )
