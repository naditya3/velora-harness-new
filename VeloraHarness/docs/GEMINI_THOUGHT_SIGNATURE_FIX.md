# Gemini 3 Thought Signature Fix for Multi-Turn Function Calling

## Overview

This document describes the fix implemented to support Gemini 3 Pro models with thinking mode (`thinkingLevel=high`) through liteLLM. The fix ensures `thought_signatures` are preserved across multi-turn function calling conversations, which is mandatory for Gemini 3's thinking mode to work correctly.

## Problem Statement

When using Gemini 3 Pro with `thinkingLevel=high` (thinking mode), the model returns `thinking_blocks` containing encrypted `thought_signatures`. These signatures must be preserved and sent back in subsequent requests for multi-turn function calling to work.

**Error without fix:**
```
geminiException - Function call is missing a thought_signature in functionCall parts
```

This error occurs on the 2nd or 3rd LLM call when:
1. Gemini returns a function call with thinking enabled
2. The function is executed and results returned
3. The next LLM call fails because `thought_signatures` were lost during message conversion

## Root Cause

OpenHands converts liteLLM responses into internal `Message` objects. During this conversion, the `thinking_blocks` attribute (which contains `thought_signatures`) was being discarded because:

1. The `Message` class didn't have a `thinking_blocks` field
2. The `conversation_memory.py` didn't extract `thinking_blocks` from liteLLM responses
3. Message serialization didn't include `thinking_blocks` when converting back to API format

## Solution

### Files Modified

1. **`openhands/core/message.py`**
   - Added `thinking_blocks: list[dict] | None = None` field to `Message` class
   - Added serialization of `thinking_blocks` in `_add_tool_call_keys()` method

2. **`openhands/memory/conversation_memory.py`**
   - Added extraction of `thinking_blocks` from liteLLM response in tool call handling
   - Added extraction of `thinking_blocks` in `AgentFinishAction` handling
   - Passes `thinking_blocks` to `Message` constructor

3. **`openhands/llm/gemini_native.py`**
   - Added `DISABLE_NATIVE_GEMINI_SDK` environment variable for testing liteLLM path
   - Kept native SDK code for future use if needed

4. **`config.toml`**
   - Added retry configuration for Gemini rate limits
   - Updated comments to document the fix

### Code Changes

#### message.py
```python
class Message(BaseModel):
    # ... existing fields ...

    # Gemini thinking blocks with thought_signatures (required for multi-turn function calling)
    thinking_blocks: list[dict] | None = None

    def _add_tool_call_keys(self, message_dict: dict[str, Any]) -> dict[str, Any]:
        # ... existing code ...

        # CRITICAL: Add thinking_blocks for Gemini thought_signature preservation
        if self.thinking_blocks is not None:
            message_dict['thinking_blocks'] = self.thinking_blocks

        return message_dict
```

#### conversation_memory.py
```python
# Extract thinking_blocks from liteLLM response
thinking_blocks = None
if hasattr(assistant_msg, 'thinking_blocks'):
    thinking_blocks = assistant_msg.thinking_blocks
elif isinstance(assistant_msg, dict) and 'thinking_blocks' in assistant_msg:
    thinking_blocks = assistant_msg['thinking_blocks']

# Pass to Message constructor
Message(
    role='assistant',
    content=[...],
    tool_calls=assistant_msg.tool_calls,
    thinking_blocks=thinking_blocks,  # Store for Gemini thought_signatures
)
```

## Configuration

### config.toml
```toml
# Gemini 3 Pro with High Reasoning Mode
[llm.gemini]
model = "gemini/gemini-3-pro-preview"
api_key = "YOUR_GOOGLE_API_KEY_HERE"
temperature = 1.0
timeout = 600  # 10 minutes for thinking-enabled calls
num_retries = 12  # More retries for rate limits
retry_min_wait = 30  # 30s between retries
retry_max_wait = 180  # Up to 3 minutes

[llm.gemini.completion_kwargs]
thinkingLevel = "high"
```

### Environment Variables

- `DISABLE_NATIVE_GEMINI_SDK=true`: Forces liteLLM path instead of native SDK (for testing)

## Testing

### Run Test
```bash
# Using liteLLM path (default with this fix)
DISABLE_NATIVE_GEMINI_SDK=true bash evaluation/benchmarks/multi_swe_bench/scripts/run_velora_infer.sh \
  llm.gemini \
  /path/to/task.jsonl \
  1 300 1
```

### Verify Success
1. Check for successful completions without thought_signature errors
2. Monitor reasoning token usage in logs:
   ```
   reasoning_tokens=1307  # Thinking mode active
   ```
3. Verify no 429 rate limit errors (or successful recovery with retries)

## Technical Details

### How Thought Signatures Work

1. **First LLM call**: Gemini returns response with `thinking_blocks` containing encrypted thought signatures
2. **Function execution**: Agent executes the requested function
3. **Second LLM call**: liteLLM must include the original `thinking_blocks` in the conversation history
4. **Gemini validation**: Gemini validates thought signatures match the thinking context

### liteLLM's Role

liteLLM handles the thought_signature preservation internally when `thinking_blocks` are present in messages. The fix ensures OpenHands preserves these blocks through its internal message conversion pipeline.

### Reasoning Token Budget

With `thinkingLevel=high`, liteLLM maps this to a thinking budget:
- `low`: 1024 tokens
- `medium`: 4096 tokens
- `high`: Automatic/maximum (model decides)

Note: liteLLM's default "high" budget is 4096 tokens, while Gemini's maximum is 24,576. This can be overridden with:
```bash
export DEFAULT_REASONING_EFFORT_HIGH_THINKING_BUDGET=24576
```

## Rate Limit Handling

Gemini 3 Pro Preview has strict rate limits. The fix includes aggressive retry configuration:

- **12 retries** with exponential backoff
- **30-180 second** wait between retries
- Recovers automatically from rate limit (429) errors

## Compatibility

- **Gemini 3 Pro Preview**: Fully supported with this fix
- **Gemini 2.5**: Not affected (no thought_signatures required)
- **Other models**: Not affected (thinking_blocks field ignored if not present)

## Related Issues

- liteLLM doesn't fully support thought_signatures in some edge cases
- Native Gemini SDK path available as fallback (set `DISABLE_NATIVE_GEMINI_SDK=false`)

## Authors

- VeloraHarness Team
- Fix implemented: February 2026
