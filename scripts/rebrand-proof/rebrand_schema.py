"""Top-level fields Rebrand's `/v1/chat/completions` accepts.

`ChatCompletionRequest` is `#[serde(deny_unknown_fields)]`
(crates/rebrand/src/ml/api_types.rs:16 in aitaco-llc/rebrand at 7d01a80):
any other top-level field is a 400. Message objects are not strict.
Re-read that struct before trusting this list against a newer Rebrand.
"""

REBRAND_REQUEST_FIELDS = frozenset(
    {
        "model",
        "messages",
        "max_tokens",
        "max_completion_tokens",
        "temperature",
        "top_p",
        "top_k",
        "min_p",
        "stream",
        "stream_options",
        "stop",
        "repeat_penalty",
        "frequency_penalty",
        "presence_penalty",
        "response_format",
        "tools",
        "constrain_tools",
        "tool_choice",
        "parallel_tool_calls",
        "seed",
        "n",
        "user",
        "logprobs",
        "top_logprobs",
        "logit_bias",
        "chat_template_kwargs",
    }
)


def unknown_fields(body):
    """Top-level request fields Rebrand would reject."""
    if not isinstance(body, dict):
        return []
    return sorted(set(body) - REBRAND_REQUEST_FIELDS)
