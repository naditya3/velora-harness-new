---
paths:
  - "openhands/llm/**/*.py"
  - "config.toml"
---

# LLM Provider Integration Rules

## GPT-5.2 Codex (xhigh Reasoning)

### Architecture
- Uses `previous_response_id` for state management
- Bypasses liteLLM entirely for Responses API
- Direct OpenAI SDK integration in `gpt_responses_openai_direct.py`

### Required Config
```toml
[llm.gpt_codex]
model = "gpt-5.2-codex"
reasoning_effort = "xhigh"
native_tool_calling = false  # MUST be false
timeout = 7200  # 2 hours
```

### State Management
```python
_response_state = {
    "conv_id": {
        "response_id": "resp_xxx",
        "processed_call_ids": {"call_xxx"}
    }
}
```

## Gemini 3 Pro (Thinking Mode)

### Critical: Thought Signature Preservation
`thinking_blocks` MUST be preserved across turns for multi-turn function calling.

### Required Fields
- `Message.thinking_blocks` - Stores encrypted thought signatures
- `conversation_memory.py` - Extracts thinking_blocks from liteLLM response

### Config
```toml
[llm.gemini]
model = "gemini/gemini-3-pro-preview"
timeout = 600
num_retries = 12
retry_min_wait = 30

[llm.gemini.completion_kwargs]
thinkingLevel = "high"
```

## Adding New Providers

1. Check if liteLLM supports the model natively
2. If special handling needed (like Codex), create `<provider>_direct.py`
3. Add routing logic in `llm.py`
4. Update config.toml with new section
5. Test with small dataset before full eval

## Never Do

- Don't remove thinking_blocks extraction (breaks Gemini)
- Don't set native_tool_calling=true for Codex
- Don't use liteLLM for Codex with reasoning_effort
