# GPT-5.2 Codex xhigh Reasoning Integration Fix

## Date: January 31, 2026

## Problem Statement
OpenHands harness was failing when using GPT-5.2 Codex with `reasoning_effort=xhigh` due to:
1. LiteLLM bugs with `reasoning_effort` parameter (GitHub issues #13699, #16032)
2. Message format incompatibility between Chat Completions API and Responses API
3. Tool call ID mismatches causing `No tool output found for function call` errors

## Solution: `previous_response_id` Architecture

We implemented direct OpenAI SDK integration that bypasses LiteLLM and uses OpenAI's built-in state management via `previous_response_id`.

### Key Files Modified

1. **`openhands/llm/gpt_responses_openai_direct.py`** (NEW FILE)
   - Direct OpenAI SDK integration for Responses API
   - State management using `previous_response_id`
   - Tracks `processed_call_ids` to avoid duplicate submissions

2. **`openhands/llm/llm.py`**
   - Added `_conversation_id` tracking per LLM instance
   - Calls `openai_responses_completion()` when `reasoning_effort` is set
   - Bypasses LiteLLM for Codex models

3. **`config.toml`**
   - Added `llm.gpt_codex` configuration section
   - Settings: `reasoning_effort = "xhigh"`, `native_tool_calling = false`

## How It Works

### First API Call
1. Convert system message to `instructions` parameter
2. Convert user messages to `input` items with `type: "message"`
3. Call `responses.create()` with `store=True`
4. Store `response.id` for next turn

### Subsequent API Calls
1. Use `previous_response_id` from stored state
2. Only send NEW `function_call_output` items (skip already-processed)
3. OpenAI manages full conversation context internally

### State Management
```python
_response_state = {
    "conv_agent_xxx": {
        "response_id": "resp_xxx",
        "pending_tool_calls": [...],
        "processed_call_ids": {"call_xxx", "call_yyy"}
    }
}
```

## Usage

```toml
# config.toml
[llm.gpt_codex]
model = "gpt-5.2-codex"
api_key = "sk-..."
reasoning_effort = "xhigh"  # Options: low, medium, high, xhigh
native_tool_calling = false  # REQUIRED for mock function calling
temperature = 0.2
timeout = 7200  # 2 hours for xhigh reasoning
```

## Test Results

| Metric | Result |
|--------|--------|
| API Errors | 0 (50 iterations) |
| ID Mismatches | 0 |
| Token Usage | 47K-84K per call (xhigh active) |
| Duration | ~17 min for 50 iterations |

## Known Limitations

1. Requires `native_tool_calling = false` (mock function calling)
2. Each task needs its own Docker runtime image
3. First call takes longer due to xhigh reasoning overhead

## Troubleshooting

### Error: `No tool output found for function call call_xxx`
- Check if `processed_call_ids` is being tracked correctly
- Verify `call_id` format matches OpenAI's format (e.g., `call_xxx`)

### Error: `context_length_exceeded`
- Reduce `max_iterations` or conversation length
- The fix prevents this by only sending new outputs, not full history

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                     OpenHands Agent                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐    ┌──────────────────────────────────────┐   │
│  │   LLM.py    │───▶│  gpt_responses_openai_direct.py      │   │
│  │             │    │                                       │   │
│  │ - conversation_id│  - previous_response_id state mgmt   │   │
│  │ - reasoning_effort│  - processed_call_ids tracking       │   │
│  └─────────────┘    │  - function_call_output conversion   │   │
│                     └──────────────────────────────────────┘   │
│                                    │                            │
│                                    ▼                            │
│                     ┌──────────────────────────────────────┐   │
│                     │     OpenAI Responses API             │   │
│                     │     (with store=True)                │   │
│                     └──────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Team Notes

- Always use `DOCKER_BUILDKIT=0` when building images
- Runtime images are task-specific - don't reuse across different tasks
- LiteLLM fallback is available if direct SDK fails

## Files to Deploy

When deploying to other instances, copy these files:
1. `openhands/llm/gpt_responses_openai_direct.py`
2. `openhands/llm/llm.py` (modified)
3. `config.toml` (with gpt_codex section)

## Author
Automated fix applied via Cursor AI assistant - January 31, 2026
