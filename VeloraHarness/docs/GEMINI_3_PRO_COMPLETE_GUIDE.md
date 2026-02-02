# Gemini 3 Pro Complete Guide - VeloraHarness

**Last Updated:** 2026-02-02
**Status:** Production Ready
**Evaluated:** 300-iteration runs validated

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Configuration](#configuration)
3. [Technical Architecture](#technical-architecture)
4. [Thinking Mode vs GPT Reasoning](#thinking-mode-vs-gpt-reasoning)
5. [Thought Signature Preservation](#thought-signature-preservation)
6. [liteLLM Integration](#litellm-integration)
7. [Token Budget Configuration](#token-budget-configuration)
8. [Rate Limit Handling](#rate-limit-handling)
9. [Evaluation Results](#evaluation-results)
10. [Usage Examples](#usage-examples)
11. [Troubleshooting](#troubleshooting)

---

## Executive Summary

Gemini 3 Pro integration with VeloraHarness uses **liteLLM with custom thought signature preservation** to enable high reasoning mode with multi-turn function calling.

### Key Facts
- **Model:** `gemini-3-pro-preview`
- **API:** Google GenAI via liteLLM
- **Bypass:** NO - uses liteLLM (unlike GPT which bypasses it)
- **Thinking Levels:** `low`, `medium`, `high`
- **Recommended:** `high` for maximum reasoning (evaluated and working)
- **Token Budget:** Configurable via environment variable (default 4096, max 24576)
- **Critical Feature:** Thought signature preservation for multi-turn function calling

---

## Configuration

### Current Production Config

**Location:** `/home/ec2-user/Jeager/Velora_SWE_Harness/VeloraHarness/config.toml`

```toml
[llm.gemini]
model = "gemini/gemini-3-pro-preview"
api_key = "AIzaSy..."  # Your Google API key
temperature = 1.0
timeout = 600  # 10 minutes for thinking-enabled calls
num_retries = 12  # More retries for rate limits
retry_min_wait = 30  # 30s between retries
retry_max_wait = 180  # Up to 3 minutes

[llm.gemini.completion_kwargs]
thinkingLevel = "high"
```

### Thinking Level Values

| Level | Default Budget | Max Budget | Duration | Use Case |
|-------|---------------|------------|----------|----------|
| `low` | 1,024 tokens | 1,024 | 5-15s | Simple queries |
| `medium` | 4,096 tokens | 4,096 | 15-60s | Standard tasks |
| `high` | 4,096 tokens | **24,576** | 30s-5min | Complex tasks (use env var) |

**Important:** To unlock the full 24,576 token budget for `high` thinking:
```bash
export DEFAULT_REASONING_EFFORT_HIGH_THINKING_BUDGET=24576
```

Without this environment variable, liteLLM restricts `high` to 4,096 tokens.

**Evaluated:** `high` with 24,576 budget tested with 300-iteration runs. Works correctly.

---

## Technical Architecture

### Why liteLLM (Unlike GPT)?

**Key Difference:** Gemini 3 Pro works correctly with liteLLM. GPT-5.2 Codex doesn't.

| Aspect | Gemini 3 Pro | GPT-5.2 Codex |
|--------|--------------|---------------|
| **API Used** | Google GenAI API | OpenAI Responses API |
| **liteLLM Support** | ✅ Full support | ⚠️ Buggy (issues #13699, #16032) |
| **State Management** | Standard messages | `previous_response_id` |
| **Integration** | Via liteLLM | Direct SDK bypass |
| **Token Budgets** | liteLLM manages | Bypassed completely |

### Why We Need Custom Code

Despite using liteLLM, we need custom code for **thought signature preservation**:

```
Configuration (config.toml)
    ↓
LLMConfig.completion_kwargs = {"thinkingLevel": "high"}
    ↓
liteLLM makes Google GenAI API call
    ↓
Response includes thinking_blocks with thought_signatures
    ↓
⚠️ CRITICAL: OpenHands must preserve thinking_blocks
    ↓
Custom code in:
  - Message.thinking_blocks field
  - conversation_memory.py extraction
    ↓
thinking_blocks sent back in next API call
    ↓
✅ Multi-turn function calling works
```

---

## Thinking Mode vs GPT Reasoning

### Conceptual Similarity

Both Gemini's "thinking mode" and GPT's "reasoning effort" enable extended reasoning:

| Feature | Gemini 3 Pro | GPT-5.2 Codex |
|---------|--------------|---------------|
| **Parameter** | `thinkingLevel` | `reasoning_effort` |
| **Levels** | low, medium, high | low, medium, high, xhigh |
| **Max Tokens** | 24,576 | Unlimited |
| **Output** | `thinking_blocks` | Reasoning tokens in response |
| **State** | `thought_signatures` | `previous_response_id` |
| **Multi-turn** | Requires signature preservation | Requires response ID tracking |

### Implementation Difference

**Gemini:** Uses standard message format + thought signatures
```python
messages = [
    {"role": "user", "content": "..."},
    {
        "role": "assistant",
        "content": "...",
        "thinking_blocks": [{"thought_signature": "encrypted_sig"}]  # ← Preserve
    },
    {"role": "user", "content": "..."}
]
```

**GPT:** Uses stateful response IDs
```python
# First call
response = client.responses.create(...)
response_id = response.id  # ← Save

# Second call
response = client.responses.create(
    previous_response_id=response_id  # ← Reference previous state
)
```

---

## Thought Signature Preservation

### The Problem

When using `thinkingLevel=high`, Gemini returns encrypted `thought_signatures` in `thinking_blocks`. These signatures **must** be sent back in the next request for multi-turn function calling to work.

**Error without preservation:**
```
geminiException - Function call is missing a thought_signature in functionCall parts
```

This error occurs on the 2nd or 3rd LLM call when:
1. Gemini returns a function call with thinking enabled
2. The function is executed and results returned
3. The next LLM call fails because thought signatures were lost

### The Solution

We modified OpenHands to preserve `thinking_blocks` through its internal message pipeline.

#### Files Modified

**1. openhands/core/message.py**
```python
class Message(BaseModel):
    role: str
    content: list[ContentItem] | str
    tool_calls: list[ToolCall] | None = None

    # Gemini thinking blocks with thought_signatures
    thinking_blocks: list[dict] | None = None  # ← ADDED

    def _add_tool_call_keys(self, message_dict: dict[str, Any]) -> dict[str, Any]:
        # ... existing tool call serialization ...

        # CRITICAL: Add thinking_blocks for Gemini thought_signature preservation
        if self.thinking_blocks is not None:
            message_dict['thinking_blocks'] = self.thinking_blocks  # ← ADDED

        return message_dict
```

**2. openhands/memory/conversation_memory.py**
```python
# Extract thinking_blocks from liteLLM response
thinking_blocks = None
if hasattr(assistant_msg, 'thinking_blocks'):
    thinking_blocks = assistant_msg.thinking_blocks
elif isinstance(assistant_msg, dict) and 'thinking_blocks' in assistant_msg:
    thinking_blocks = assistant_msg['thinking_blocks']

# Create Message with thinking_blocks
Message(
    role='assistant',
    content=content,
    tool_calls=assistant_msg.tool_calls,
    thinking_blocks=thinking_blocks,  # ← Preserve for next call
)
```

### How It Works

1. **Gemini Response:** liteLLM receives response with `thinking_blocks`
2. **Extraction:** `conversation_memory.py` extracts `thinking_blocks` from liteLLM response
3. **Storage:** Stored in `Message.thinking_blocks` field
4. **Serialization:** When converting back to API format, `_add_tool_call_keys()` includes `thinking_blocks`
5. **Next Call:** liteLLM sends `thinking_blocks` back to Gemini
6. **Validation:** Gemini validates signatures and allows function call to proceed

---

## liteLLM Integration

### Architecture Decision

**Why We Use liteLLM for Gemini:**

✅ **Advantages:**
- liteLLM has full Google GenAI API support
- No known bugs with Gemini 3 thinking mode
- Handles retries, rate limits, logging automatically
- Standard message format works (with our thought signature fix)

❌ **GPT Can't Use liteLLM Because:**
- liteLLM's Responses API support is buggy (GitHub issues #13699, #16032)
- `reasoning_effort=xhigh` not properly supported
- `previous_response_id` state management broken
- Token budgets incorrectly restricted

### liteLLM Call Flow

```python
# In openhands/llm/llm.py
def completion(self, messages, **kwargs):
    # Gemini uses standard liteLLM path
    response = litellm.completion(
        model="gemini/gemini-3-pro-preview",
        messages=messages,
        thinkingLevel="high",  # From completion_kwargs
        **kwargs
    )

    # Response includes thinking_blocks
    # Our custom code preserves them (see above)
    return response
```

**No Bypass:** Unlike GPT which completely bypasses liteLLM, Gemini goes through liteLLM normally.

---

## Token Budget Configuration

### Default liteLLM Budgets

liteLLM has built-in thinking token budgets:

| Thinking Level | liteLLM Default | Gemini Maximum |
|----------------|-----------------|----------------|
| `low` | 1,024 | 1,024 |
| `medium` | 4,096 | 4,096 |
| `high` | 4,096 | 24,576 |

### Unlocking Full Budget

To use the full 24,576 token budget for `high` thinking:

**1. Set Environment Variable:**
```bash
export DEFAULT_REASONING_EFFORT_HIGH_THINKING_BUDGET=24576
```

**2. Add to Shell Profile:**
```bash
echo 'export DEFAULT_REASONING_EFFORT_HIGH_THINKING_BUDGET=24576' >> ~/.bashrc
source ~/.bashrc
```

**3. Verify:**
```bash
echo $DEFAULT_REASONING_EFFORT_HIGH_THINKING_BUDGET
# Should output: 24576
```

**4. Run Evaluation:**
```bash
bash evaluation/benchmarks/multi_swe_bench/scripts/run_velora_infer.sh \
  llm.gemini \
  /path/to/task.jsonl \
  1 300 1
```

### Monitoring Token Usage

Check logs for reasoning token consumption:
```
[INFO] Gemini completion: reasoning_tokens=8421
```

If you see reasoning tokens capped at ~4096 consistently, the environment variable isn't set.

---

## Rate Limit Handling

### Gemini 3 Pro Preview Rate Limits

Gemini 3 Pro Preview has **strict rate limits**:
- **Requests per minute (RPM):** 10-15
- **Tokens per minute (TPM):** 100K-200K
- **Concurrent requests:** 1-2

### Aggressive Retry Configuration

Our config handles rate limits gracefully:

```toml
[llm.gemini]
timeout = 600           # 10 minutes (thinking can be slow)
num_retries = 12        # Many retries
retry_min_wait = 30     # Start at 30 seconds
retry_max_wait = 180    # Up to 3 minutes between retries
```

### Exponential Backoff

liteLLM implements exponential backoff:
1. First retry: 30s wait
2. Second retry: 45s wait
3. Third retry: 67s wait
4. ...
5. Max retry: 180s wait

**Result:** Evaluation continues even with heavy rate limiting. Expect ~1 hour per task with high thinking.

### 429 Error Handling

When rate limited:
```
[WARNING] Rate limit hit (429), retrying in 45 seconds... (attempt 3/12)
```

This is **expected and normal**. The system will recover automatically.

---

## Evaluation Results

### Production Validation

**Test Configuration:**
- Model: `gemini-3-pro-preview`
- Thinking: `thinkingLevel=high` with 24,576 budget
- Dataset: PHP Laravel SWE-bench task
- Iterations: 300 max
- Runtime: ~45 minutes per task

**Results:**
✅ Thought signatures preserved correctly
✅ Multi-turn function calling worked
✅ No signature errors
✅ Reasoning tokens: 1,307-8,421 per turn
✅ Rate limits handled gracefully

### Token Consumption

**Average per task:**
- Input tokens: 80K-150K
- Output tokens: 15K-30K
- Reasoning tokens: 5K-15K
- Total: ~100K-200K tokens

**Cost estimate (approximate):**
- Input: $0.10-0.20
- Output: $0.30-0.60
- Total: ~$0.40-0.80 per task

---

## Usage Examples

### Running Single Task

```bash
cd /home/ec2-user/Jeager/Velora_SWE_Harness/VeloraHarness

# Set budget
export DEFAULT_REASONING_EFFORT_HIGH_THINKING_BUDGET=24576

# Run evaluation
bash evaluation/benchmarks/multi_swe_bench/scripts/run_velora_infer.sh \
  llm.gemini \
  data/sample_task.jsonl \
  1 300 1
```

### Running Full Evaluation

```bash
# Set budget
export DEFAULT_REASONING_EFFORT_HIGH_THINKING_BUDGET=24576

# Run full pipeline
bash run_full_eval_with_s3.sh \
  llm.gemini \
  data/datasets/php_laravel_subset.jsonl \
  300 \
  gemini-3-high-php-eval
```

### Testing Thought Signature Fix

```bash
# Run with verbose logging
export LITELLM_LOG=DEBUG
export DEFAULT_REASONING_EFFORT_HIGH_THINKING_BUDGET=24576

python evaluation/benchmarks/multi_swe_bench/run_infer.py \
  --agent-cls CodeActAgent \
  --llm-config llm.gemini \
  --max-iterations 300 \
  --eval-n-limit 1 \
  --eval-ids instance_id_here
```

Look for in logs:
```
[DEBUG] thinking_blocks found in response
[DEBUG] Preserving thought_signatures for next call
[INFO] reasoning_tokens=4532
```

---

## Troubleshooting

### Thought Signature Error

**Error:**
```
geminiException - Function call is missing a thought_signature in functionCall parts
```

**Cause:** Thought signatures not preserved through message pipeline

**Fix:**
1. Verify `Message.thinking_blocks` field exists in `openhands/core/message.py`
2. Verify extraction in `openhands/memory/conversation_memory.py`
3. Check serialization in `Message._add_tool_call_keys()`

**Quick test:**
```python
# In openhands/memory/conversation_memory.py, add logging:
if thinking_blocks:
    logger.info(f"[THINKING] Preserved {len(thinking_blocks)} thinking blocks")
else:
    logger.warning("[THINKING] No thinking blocks found - signature error likely")
```

### Rate Limit 429 Errors

**Error:**
```
Status 429: Resource has been exhausted (e.g. check quota)
```

**Cause:** Gemini 3 Pro Preview has strict rate limits

**Solution:** This is expected - the retry logic handles it. If retries exhausted:
1. Increase `num_retries` in config.toml
2. Increase `retry_max_wait` to 300 seconds
3. Add delays between tasks in batch runs

### Reasoning Tokens Capped at ~4K

**Symptom:** Logs show `reasoning_tokens` never exceeding 4,000-4,500

**Cause:** Environment variable not set

**Fix:**
```bash
export DEFAULT_REASONING_EFFORT_HIGH_THINKING_BUDGET=24576
```

Verify it's set:
```bash
env | grep DEFAULT_REASONING
```

### Empty or Failed Responses

**Error:**
```
litellm.Timeout: Request timed out
```

**Cause:** Thinking mode can take 2-5 minutes per call

**Fix:**
1. Increase timeout in config.toml:
   ```toml
   timeout = 600  # 10 minutes
   ```
2. For very complex tasks, increase to 900 (15 minutes)

### Import Error for Native Gemini

**Warning:**
```
Native Gemini SDK not available - thought_signatures not supported
```

**Cause:** Dead code from removed native SDK

**Solution:** Ignore this warning - it's harmless. Thought signatures work via liteLLM path.

**Optional cleanup:** Remove dead code in `openhands/llm/llm.py`:
```python
# Lines 43-52: Remove try-except for gemini_native import
# Line 350: Remove NATIVE_GEMINI_AVAILABLE check
```

---

## Architecture Comparison: Gemini vs GPT

### Summary Table

| Aspect | Gemini 3 Pro | GPT-5.2 Codex |
|--------|--------------|---------------|
| **Integration** | liteLLM | Direct OpenAI SDK |
| **Bypass liteLLM?** | ❌ No | ✅ Yes (completely) |
| **Reasoning Param** | `thinkingLevel` | `reasoning_effort` |
| **Max Reasoning** | `high` (24,576 tokens) | `xhigh` (unlimited) |
| **Custom Code** | Thought signature preservation | Full SDK implementation |
| **State Management** | Standard messages + signatures | `previous_response_id` |
| **Token Budget** | liteLLM enforced (configurable) | No restrictions |
| **Rate Limits** | Very strict (10-15 RPM) | Moderate |
| **Cost** | ~$0.40-0.80/task | ~$1-3/task |
| **Files Modified** | 2 (message.py, conversation_memory.py) | 3 (+ gpt_responses_openai_direct.py) |

### When to Use Which?

**Use Gemini 3 Pro when:**
- Cost-sensitive projects
- Python/PHP SWE-bench tasks
- Willing to wait for rate limits
- Standard function calling sufficient

**Use GPT-5.2 Codex when:**
- Maximum reasoning needed (xhigh)
- Faster turnaround required
- Budget allows higher cost
- Complex multi-step tasks

---

## Related Documentation

- [GEMINI_THOUGHT_SIGNATURE_FIX.md](GEMINI_THOUGHT_SIGNATURE_FIX.md) - Original fix details
- [GPT_CODEX_COMPLETE_GUIDE.md](GPT_CODEX_COMPLETE_GUIDE.md) - GPT comparison
- [.claude/rules/llm-providers.md](../.claude/rules/llm-providers.md) - Quick reference

---

## Changelog

**2026-02-02:** Initial comprehensive guide created
- Consolidated thought signature fix documentation
- Added token budget configuration details
- Documented liteLLM integration approach
- Added comparison with GPT architecture
- Included production validation results

---

## Authors

- VeloraHarness Team
- Guide created: February 2026
