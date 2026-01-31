# GPT-5.2 Codex xhigh Reasoning Process Guide

## Date: January 31, 2026

This guide provides the complete step-by-step process for running GPT-5.2 Codex with `reasoning_effort=xhigh`.

---

## Quick Reference

| Parameter | Value | Notes |
|-----------|-------|-------|
| `model` | `gpt-5.2-codex` | Required |
| `reasoning_effort` | `xhigh` | Maximum reasoning depth |
| `native_tool_calling` | `false` | REQUIRED - use mock function calling |
| `temperature` | `0.2` | Recommended for consistency |
| `timeout` | `7200` | 2 hours - xhigh calls can take 5-10 min |
| `max_iterations` | `300` | Recommended for complex tasks |

---

## Prerequisites Checklist

- [ ] OpenAI API key with GPT-5.2 Codex access
- [ ] Docker installed and running
- [ ] VeloraHarness with xhigh fix applied (see `GPT_CODEX_XHIGH_FIX.md`)
- [ ] Task dataset (JSONL format)
- [ ] Docker images for tasks available

---

## Step-by-Step Process

### Step 1: Verify the Fix is Applied

Before running, confirm the critical files are in place:

```bash
cd ~/VeloraHarness_clean

# 1. Check gpt_responses_openai_direct.py exists and has previous_response_id
grep "previous_response_id" openhands/llm/gpt_responses_openai_direct.py
# Expected: Should show multiple matches

# 2. Check llm.py has conversation_id tracking
grep "conversation_id" openhands/llm/llm.py
# Expected: Should show _conversation_id initialization

# 3. Check config has correct settings
grep -A 10 "\[llm.gpt_codex\]" config.toml
```

### Step 2: Configure for xhigh

Edit `config.toml`:

```toml
[llm.gpt_codex]
model = "gpt-5.2-codex"
api_key = "sk-..."  # Your OpenAI API key
reasoning_effort = "xhigh"
native_tool_calling = false  # CRITICAL - must be false
temperature = 0.2
timeout = 7200

# Optional but recommended
max_input_tokens = 120000
max_output_tokens = 65536
```

Also set in `[core]`:

```toml
[core]
max_iterations = 300  # High for complex tasks
```

### Step 3: Set Environment Variables

```bash
# REQUIRED - prevents Docker build issues
export DOCKER_BUILDKIT=0

# OPTIONAL - if using pre-built instance images
export EVAL_DOCKER_IMAGE_PREFIX=mswebench
export USE_INSTANCE_IMAGE=true

# DO NOT SET - let harness build fresh runtime each task
# unset RUNTIME_CONTAINER_IMAGE
```

### Step 4: Prepare Dataset

Ensure your dataset JSONL has all required fields:

```json
{
  "instance_id": "owner__repo-123",
  "repo": "owner/repo",
  "base_commit": "abc123...",
  "problem_statement": "Description of the issue...",
  "hints_text": "",
  "test_patch": "...",
  "patch": "..."
}
```

### Step 5: Run Inference

```bash
cd ~/VeloraHarness_clean

poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent-cls CodeActAgent \
    --llm-config gpt_codex \
    --max-iterations 300 \
    --eval-num-workers 1 \
    --dataset /path/to/your/dataset.jsonl \
    --split train \
    --eval-n-limit 1
```

### Step 6: Monitor Execution

**Expected Behavior for xhigh:**

1. **First API Call**: 2-5 minutes
   - Model reads problem statement
   - Generates comprehensive reasoning (40K-80K tokens)
   - Outputs first action

2. **Subsequent Calls**: 1-5 minutes each
   - Uses `previous_response_id` for context
   - Only new tool outputs sent
   - Reasoning continues from prior state

3. **Token Usage per Call**:
   - Input: 5K-20K tokens
   - Output: 40K-100K tokens
   - Most output is reasoning tokens

**Monitor with:**

```bash
# Watch logs in real-time
tail -f output/eval_*/instances/*.log

# Check LLM completions
ls -la output/eval_*/llm_completions/gpt-5.2-codex/
```

### Step 7: Verify Success

After completion, check:

```bash
# 1. Check for git patch in output
cat output/eval_*/output.jsonl | jq '.git_patch'

# 2. Check error status
cat output/eval_*/output.jsonl | jq '.error'
# Expected: null

# 3. Check token usage (should be high for xhigh)
cat output/eval_*/llm_completions/gpt-5.2-codex/*.json | jq '.model_response.usage'
```

---

## Timing Expectations

| Operation | xhigh Duration | Notes |
|-----------|---------------|-------|
| First API call | 2-5 minutes | Model analyzing problem |
| Tool execution | 1-30 seconds | Depends on command |
| Subsequent API calls | 1-5 minutes | Reasoning continues |
| Full task (10 iterations) | 10-30 minutes | Varies by complexity |
| Full task (50 iterations) | 30-120 minutes | Complex problems |
| Full task (300 iterations) | 2-6 hours | Maximum reasoning |

**Important**: Do NOT kill the process if it seems slow. xhigh reasoning genuinely takes time.

---

## Comparing Reasoning Levels

| Aspect | medium | high | xhigh |
|--------|--------|------|-------|
| API call time | 5-30s | 30s-2min | 1-5min |
| Output tokens | 5K-20K | 20K-50K | 40K-100K |
| Reasoning depth | Basic | Thorough | Maximum |
| Use case | Simple tasks | Most tasks | Hardest problems |
| Cost | $ | $$ | $$$ |

---

## Troubleshooting Quick Reference

| Symptom | Likely Cause | Solution |
|---------|-------------|----------|
| API calls < 5 seconds | Reasoning not applied | Check `reasoning_effort` in config |
| `No tool output for call_XXX` | ID mismatch | Check `call_id` extraction |
| `context_length_exceeded` | Not using previous_response_id | Verify fix is applied |
| `Invalid value: 'tool'` | Wrong API format | Check routing to direct SDK |
| Docker build fails | Missing tmux | Check Dockerfile.j2 |
| Wrong repo files | Stale runtime | Clear docker, rebuild |

See `GPT_CODEX_DEBUGGING_GUIDE.md` for detailed debugging.

---

## Best Practices

### 1. One Task at a Time

For xhigh, run `eval-num-workers 1` to avoid API rate limits and ensure proper state management.

### 2. Monitor Token Usage

Check that reasoning tokens are being generated:

```bash
cat output/eval_*/llm_completions/gpt-5.2-codex/*.json | jq '.model_response.usage.output_tokens_details.reasoning_tokens'
```

Should be 30K-90K for xhigh.

### 3. Don't Interrupt

If a task is running, let it complete. Interrupting mid-reasoning wastes the API call.

### 4. Check Response Chain

Verify `previous_response_id` is being used:

```bash
# In logs, look for:
# "Using previous_response_id: resp_xxx"
# "Stored new response_id: resp_yyy"
```

### 5. Fresh Runtime Per Task

Always let the harness build a new runtime for each task to avoid cross-contamination.

---

## Files Reference

| File | Purpose |
|------|---------|
| `config.toml` | Main configuration |
| `openhands/llm/llm.py` | Routes to direct SDK |
| `openhands/llm/gpt_responses_openai_direct.py` | OpenAI Responses API integration |
| `docs/GPT_CODEX_XHIGH_FIX.md` | Technical fix documentation |
| `docs/GPT_CODEX_DEBUGGING_GUIDE.md` | Error reference |

---

## Example Successful Run

```
$ poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent-cls CodeActAgent \
    --llm-config gpt_codex \
    --max-iterations 10 \
    --eval-num-workers 1 \
    --dataset ~/datasets/test_task.jsonl

[INFO] Loading configuration...
[INFO] Using GPT-5.2 Codex with reasoning_effort=xhigh
[INFO] Starting task: owner__repo-123
[INFO] Building runtime container...
[INFO] Runtime ready
[INFO] Iteration 1/10 - API call starting...
[INFO] Iteration 1/10 - Completed in 187.3s (reasoning_tokens: 67234)
[INFO] Iteration 2/10 - API call starting...
[INFO] Using previous_response_id: resp_abc123
[INFO] Iteration 2/10 - Completed in 142.1s (reasoning_tokens: 54123)
...
[INFO] Task completed successfully
[INFO] Git patch generated: 1,234 bytes
[INFO] Total duration: 547.2s
```

---

**Last Updated**: January 31, 2026
**Version**: 1.0
