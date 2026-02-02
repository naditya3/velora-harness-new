# GPT-5.2 Codex Debugging Guide

## Date: January 31, 2026

This comprehensive guide covers all known error patterns, their root causes, and fixes for GPT-5.2 Codex integration with VeloraHarness.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Error Pattern Reference](#error-pattern-reference)
3. [Debugging Workflow](#debugging-workflow)
4. [Log Analysis](#log-analysis)
5. [Common Pitfalls](#common-pitfalls)
6. [Quick Fixes](#quick-fixes)

---

## Architecture Overview

### How GPT-5.2 Codex Works in VeloraHarness

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         VeloraHarness                                    │
│                                                                          │
│  ┌────────────────┐    ┌─────────────────────────────────────────────┐  │
│  │  CodeActAgent  │───▶│  ConversationMemory                         │  │
│  │                │    │  (manages message history)                  │  │
│  └────────────────┘    └─────────────────────────────────────────────┘  │
│          │                              │                                │
│          ▼                              ▼                                │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │  LLM.py                                                            │ │
│  │  - Detects reasoning_effort in config                              │ │
│  │  - Routes to gpt_responses_openai_direct.py (bypasses LiteLLM)     │ │
│  │  - Generates unique conversation_id per instance                   │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                               │                                          │
│                               ▼                                          │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │  gpt_responses_openai_direct.py (DIRECT OpenAI SDK)                │ │
│  │                                                                     │ │
│  │  State Management:                                                  │ │
│  │  _response_state = {                                                │ │
│  │      "conv_xxx": {                                                  │ │
│  │          "response_id": "resp_xxx",      ← For next API call        │ │
│  │          "pending_tool_calls": [...],    ← Awaiting tool results    │ │
│  │          "processed_call_ids": {...}     ← Already sent to API      │ │
│  │      }                                                              │ │
│  │  }                                                                  │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                               │                                          │
│                               ▼                                          │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │  OpenAI Responses API (with store=True)                            │ │
│  │  - Uses previous_response_id for conversation continuity           │ │
│  │  - Manages full context internally                                 │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### Key Difference: Chat Completions vs Responses API

| Aspect | Chat Completions API | Responses API (Codex) |
|--------|---------------------|----------------------|
| Message Format | `role: user/assistant/system/tool` | `type: message/function_call/function_call_output` |
| Tool Results | `role: "tool"` with `tool_call_id` | `type: "function_call_output"` with `call_id` |
| State Management | Send full history each call | Use `previous_response_id` |
| System Message | `role: "system"` | `instructions` parameter |

---

## Error Pattern Reference

### 1. `Invalid value: 'tool'. Supported values are: 'assistant', 'system', 'developer', and 'user'`

**Root Cause**: Sending Chat Completions format to Responses API

**Solution**: The harness now converts `role='tool'` messages to `type='function_call_output'` items automatically. If you see this error:

1. Check that `gpt_responses_openai_direct.py` is being called
2. Verify `reasoning_effort` is set in config
3. Check llm.py is routing correctly

```python
# In llm.py, should see this routing:
if self.config.reasoning_effort:
    from openhands.llm.gpt_responses_openai_direct import openai_responses_completion
    response = openai_responses_completion(...)
```

---

### 2. `No tool output found for function call call_XXX`

**Root Cause**: Tool call ID mismatch between what model expects and what we're sending

**Background**: OpenAI returns tool calls with two IDs:
- `item.id` - The item ID (e.g., `item_xxx`)
- `item.call_id` - The function call ID (e.g., `call_xxx`)

The `function_call_output` must reference the `call_id`, NOT the `item.id`.

**Solution**: Check `gpt_responses_openai_direct.py` extracts `call_id` correctly:

```python
# CORRECT - use call_id
tool_call_id = getattr(item, 'call_id', None) or getattr(item, 'id', None)

# WRONG - using item.id
tool_call_id = item.id  # This causes the error!
```

**Debugging Steps**:
1. Enable debug logging in gpt_responses_openai_direct.py
2. Check what `call_id` values are being extracted from model response
3. Check what `call_id` values are being sent in `function_call_output` items
4. They must match exactly

---

### 3. `context_length_exceeded`

**Root Cause**: Conversation history growing too large

**Why It Happens**:
- Original approach: Sending full message history each call
- With xhigh reasoning, each turn generates 50K-100K tokens
- After 5-10 turns, context explodes

**Solution**: The `previous_response_id` architecture fixes this by:
1. Using `store=True` to let OpenAI store conversation
2. Using `previous_response_id` to reference prior context
3. Only sending NEW `function_call_output` items

**Verification**:
```python
# In gpt_responses_openai_direct.py, check:
# 1. First call stores response_id
store_conversation_state(conversation_id, {
    "response_id": response.id,  # ← This gets stored
    ...
})

# 2. Subsequent calls use it
response = client.responses.create(
    previous_response_id=state["response_id"],  # ← Used here
    ...
)

# 3. processed_call_ids prevents re-sending old outputs
if call_id not in state.get("processed_call_ids", set()):
    input_items.append(function_call_output_item)
```

---

### 4. `Invalid 'input[X].id': 'toolu_XXX'. Expected an ID that begins with 'fc'`

**Root Cause**: Tool call IDs from other providers (like Claude's `toolu_` prefix) being sent to OpenAI

**Solution**: This is handled by using `previous_response_id` approach, which only sends OpenAI's native `call_XXX` IDs.

**If You See This**:
1. Check if LiteLLM is being used (it shouldn't for Codex)
2. Verify the routing in llm.py goes to `openai_responses_completion()`
3. Check that conversation state isn't being corrupted

---

### 5. `Missing required parameter: 'tools[0].name'`

**Root Cause**: Tool definitions format mismatch

**Chat Completions Format** (WRONG for Responses API):
```json
{
  "type": "function",
  "function": {
    "name": "read_file",
    "description": "...",
    "parameters": {...}
  }
}
```

**Responses API Format** (CORRECT):
```json
{
  "type": "function",
  "name": "read_file",
  "description": "...",
  "parameters": {...}
}
```

**Solution**: The harness converts tool definitions automatically. If you see this error, check the tool conversion logic in `gpt_responses_openai_direct.py`.

---

### 6. Iterations Running Too Fast (API Call < 1 second)

**Root Cause**: xhigh reasoning not being applied

**Expected Behavior**:
- xhigh: 1-5 minutes per API call
- high: 30s-2 minutes per API call
- medium: 5-30 seconds per API call

**If Calls Are Instant**:
1. Check `reasoning_effort` is being passed to API:
   ```bash
   grep -r "reasoning_effort" ~/VeloraHarness_clean/output/llm_completions/
   ```

2. Verify config.toml has correct setting:
   ```toml
   [llm.gpt_codex]
   reasoning_effort = "xhigh"
   ```

3. Check API response has reasoning tokens in usage:
   ```json
   "usage": {
     "input_tokens": 5000,
     "output_tokens": 47000,  // ← xhigh generates 40K-100K output
     "output_tokens_details": {
       "reasoning_tokens": 45000  // ← Most should be reasoning
     }
   }
   ```

---

### 7. Docker Runtime Build Issues

**Error**: `TmuxCommandNotFound` or runtime container crashes

**Root Cause**: Runtime image missing tmux

**Solution**: Ensure `Dockerfile.j2` template includes tmux for mswebench images:

```dockerfile
{% if ('mswebench' in base_image) %}
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    wget curl ca-certificates sudo git jq \
    coreutils util-linux procps findutils grep sed \
    tmux build-essential || true && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
{% endif %}
```

**File Location**: `openhands/runtime/utils/runtime_templates/Dockerfile.j2`

---

### 8. Wrong Docker Image for Task

**Symptom**: Agent trying to access files from different repository

**Root Cause**: Reusing runtime image from previous task

**Solution**: 
1. Don't set `RUNTIME_CONTAINER_IMAGE` environment variable
2. Let harness build fresh runtime for each task
3. Clean up old containers: `docker system prune -f`

---

## Debugging Workflow

### Step 1: Check Configuration

```bash
# Verify config
cd ~/VeloraHarness_clean
cat config.toml | grep -A 10 "\[llm.gpt_codex\]"

# Expected:
# [llm.gpt_codex]
# model = "gpt-5.2-codex"
# reasoning_effort = "xhigh"
# native_tool_calling = false
# timeout = 7200
```

### Step 2: Check Logs During Run

```bash
# Watch the output in real-time
tail -f output/eval_*/instances/*.log

# Check LLM completions for reasoning_effort
ls output/eval_*/llm_completions/gpt-5.2-codex/*.json | head -1 | xargs cat | jq '.model_response.usage'
```

### Step 3: Check API Response Format

After a run, examine the LLM completion logs:

```bash
# Get latest completion file
LATEST=$(ls -t output/eval_*/llm_completions/gpt-5.2-codex/*.json | head -1)

# Check response format
cat $LATEST | jq '.model_response'

# Check for reasoning tokens
cat $LATEST | jq '.model_response.usage.output_tokens_details'
```

### Step 4: Check for Errors

```bash
# Search for common error patterns
grep -r "Invalid value" output/eval_*/instances/
grep -r "No tool output" output/eval_*/instances/
grep -r "context_length_exceeded" output/eval_*/instances/
```

---

## Log Analysis

### What to Look For in Successful Run

1. **Token Usage**: xhigh should show 40K-100K output tokens
   ```json
   "usage": {
     "output_tokens": 65536,
     "output_tokens_details": {
       "reasoning_tokens": 63000
     }
   }
   ```

2. **API Call Duration**: 1-5 minutes per call for xhigh

3. **Tool Calls**: Should see `call_XXX` format IDs

4. **Response ID Chain**: Each response should reference previous
   ```
   Call 1: response_id = resp_abc
   Call 2: previous_response_id = resp_abc, response_id = resp_def
   Call 3: previous_response_id = resp_def, response_id = resp_ghi
   ```

### What Indicates Problems

1. **Instant API calls** (<5 seconds for xhigh) → Reasoning not working
2. **Growing input tokens** (50K→100K→200K) → Not using previous_response_id
3. **ID format mismatches** (toolu_ vs call_ vs fc_) → Wrong API path
4. **Empty tool outputs** → call_id extraction bug

---

## Common Pitfalls

### 1. Forgetting to Set `native_tool_calling = false`

The harness uses mock function calling format. If native_tool_calling is true, tool definitions won't be sent correctly.

### 2. Mixing LiteLLM and Direct SDK

If both paths are active, state can get corrupted. Ensure `reasoning_effort` triggers the direct SDK path exclusively.

### 3. Reusing State Across Tasks

Each task should get a fresh `conversation_id`. If running multiple tasks, ensure state is cleared:

```python
# This happens automatically in llm.py __init__:
self._conversation_id = f"conv_{self.service_id}_{uuid.uuid4().hex[:8]}"
```

### 4. Not Waiting Long Enough

xhigh reasoning takes time. Don't kill the process if it seems stuck - API calls can legitimately take 5-10 minutes.

```toml
# Set appropriate timeout
[llm.gpt_codex]
timeout = 7200  # 2 hours
```

---

## Quick Fixes

### Fix 1: Reset Everything

```bash
cd ~/VeloraHarness_clean
docker system prune -f
rm -rf output/eval_*
poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py ...
```

### Fix 2: Force Fresh Runtime

```bash
unset RUNTIME_CONTAINER_IMAGE
export DOCKER_BUILDKIT=0
```

### Fix 3: Check API Key

```bash
# Test API key works
python -c "
from openai import OpenAI
client = OpenAI()
print(client.models.list())
"
```

### Fix 4: Verify File Modifications

```bash
# Check the critical files are modified
grep -l "previous_response_id" openhands/llm/*.py
# Should show: gpt_responses_openai_direct.py

grep -l "conversation_id" openhands/llm/llm.py
# Should show: llm.py
```

---

## Contact

For issues not covered here, check:
1. OpenAI API documentation: https://platform.openai.com/docs/guides/migrate-to-responses
2. OpenAI Community: https://community.openai.com
3. VeloraHarness logs in `output/eval_*/instances/`

---

**Last Updated**: January 31, 2026
**Version**: 2.0
