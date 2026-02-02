# GPT-5.2-codex Testing Checklist

## Pre-Testing Setup

### Configuration
- [x] Added `[llm.gpt_codex]` section to config.toml
- [x] Set `model = "gpt-5.2-codex"`
- [x] Set `reasoning_effort = "high"`
- [x] Configured token limits (120K input, 65K output)
- [x] Validation script passes
- [ ] **REQUIRED**: Add actual OpenAI API key

### Environment
- [ ] Docker is installed and running
- [ ] Python environment is active
- [ ] Required dependencies installed
- [ ] Sufficient disk space for logs

## Test Phase 1: Configuration Validation

### Step 1.1: Run Validation Script
```bash
cd /Users/macbookpro/Documents/SWE_Bench/Velora_SWE_Harness/VeloraHarness
python test_gpt_codex_config_simple.py
```

**Expected Result**: "Configuration Test: PASSED"

### Step 1.2: Check API Key
- [ ] API key is not "YOUR_OPENAI_API_KEY_HERE"
- [ ] API key starts with "sk-"
- [ ] API key has access to GPT-5.2-codex

## Test Phase 2: Single Task Test

### Step 2.1: Prepare Test Environment
```bash
cd /Users/macbookpro/Documents/SWE_Bench/Velora_SWE_Harness/VeloraHarness
```

### Step 2.2: Run First Test
```bash
python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent_cls CodeActAgent \
    --llm_config gpt_codex \
    --max_iterations 200 \
    --dataset data/test_task.jsonl \
    --split test \
    --eval_n_limit 1 \
    --eval_num_workers 1
```

### Step 2.3: Monitor Execution
- [ ] Agent initializes without import errors
- [ ] API authentication succeeds (no 401/403 errors)
- [ ] Docker container starts (or runs without Docker)
- [ ] LLM calls succeed (check terminal output)
- [ ] No fatal exceptions

### Step 2.4: Check Output
**Output Directory**: Look for newest directory in current path

- [ ] `output.jsonl` file exists
- [ ] `metadata.json` file exists
- [ ] `llm_completions/` directory exists
- [ ] Git patch was generated

### Step 2.5: Verify Reasoning Effort
**Check LLM completion logs**:
```bash
# Find the completion logs
ls -la llm_completions/*/gpt-5.2-codex-*.json

# Check for reasoning_effort parameter
cat llm_completions/*/gpt-5.2-codex-*.json | grep "reasoning_effort"
```

**Expected**: Should see `"reasoning_effort": "high"` in API requests

## Test Phase 3: Multiple Tasks

### Step 3.1: Run Multiple Tasks
```bash
python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent_cls CodeActAgent \
    --llm_config gpt_codex \
    --max_iterations 200 \
    --dataset data/sample_task.jsonl \
    --split test \
    --eval_n_limit 3 \
    --eval_num_workers 1
```

### Step 3.2: Collect Metrics
- [ ] Record success rate (X/3 tasks completed)
- [ ] Note average iterations per task
- [ ] Check token usage in logs
- [ ] Time total execution
- [ ] Document any errors

## Verification Checklist

### API Calls
- [ ] OpenAI API is being called (not errors)
- [ ] Model "gpt-5.2-codex" is specified in logs
- [ ] `reasoning_effort: "high"` appears in API requests
- [ ] Token counts are within limits
- [ ] No rate limit errors

### Agent Behavior
- [ ] Agent can read files
- [ ] Agent can execute bash commands
- [ ] Agent can write/edit files
- [ ] Agent generates git patches
- [ ] Agent completes within max_iterations

### Output Quality
- [ ] Git patches are non-empty
- [ ] Patches are valid diff format
- [ ] Changes address the problem statement
- [ ] No syntax errors in generated code
- [ ] Test commands are attempted

## Common Issues and Solutions

### Issue: "Invalid API key"
```bash
# Check your config
grep "api_key" config.toml | grep gpt_codex
```
- [ ] Fixed by updating API key in config.toml

### Issue: "Model 'gpt-5.2-codex' not found"
- [ ] Verified OpenAI account has access
- [ ] Checked API key permissions
- [ ] Contacted OpenAI support if needed

### Issue: "reasoning_effort parameter not accepted"
- [ ] Verified OpenAI API version
- [ ] Checked LiteLLM version
- [ ] Reviewed OpenAI changelog

### Issue: Docker errors
```bash
# Try without instance images
export USE_INSTANCE_IMAGE=false
```
- [ ] Docker is running
- [ ] Docker has sufficient resources
- [ ] Or running without instance images

### Issue: Import errors
```bash
# Check Python version
python --version

# Verify environment
which python
```
- [ ] Python 3.8+ required
- [ ] Correct environment activated
- [ ] Dependencies installed

## Performance Metrics to Track

### Per Task
- Task ID: ________________
- Status: [ ] Success [ ] Failure [ ] Partial
- Iterations used: _____ / 200
- Input tokens: __________
- Output tokens: __________
- Time elapsed: __________ minutes
- Errors encountered: _________________

### Summary (After 3+ Tasks)
- Success rate: _____ %
- Avg iterations: _____
- Avg input tokens: _____
- Avg output tokens: _____
- Avg time: _____ minutes
- Total cost estimate: $ _____

## Comparison Metrics (Optional)

Run same tasks with other models for comparison:

### GPT-5.1
```bash
--llm_config gpt  # uses gpt-5.1-2025-11-13
```
- [ ] Completed comparison

### Claude Sonnet 4.5
```bash
--llm_config claude  # uses claude-sonnet-4-5-20250929
```
- [ ] Completed comparison

### Kimi K2 Thinking
```bash
--llm_config kimi  # uses kimi-k2-thinking-turbo
```
- [ ] Completed comparison

## Sign-Off Checklist

### Before Declaring Success
- [ ] At least 1 task completed successfully
- [ ] API calls verified with reasoning_effort
- [ ] Output format is correct
- [ ] No blocking errors
- [ ] Documentation updated with findings

### Before AWS Deployment
- [ ] Minimum 10 tasks tested
- [ ] Performance metrics collected
- [ ] Cost estimates calculated
- [ ] Comparison with other models done
- [ ] Team approval obtained
- [ ] **DO NOT DEPLOY YET** (per instructions)

## Notes and Observations

### Test Run 1 (Date: ________)
```
Task: _______________
Result: _______________
Issues: _______________
```

### Test Run 2 (Date: ________)
```
Task: _______________
Result: _______________
Issues: _______________
```

### Test Run 3 (Date: ________)
```
Task: _______________
Result: _______________
Issues: _______________
```

## Final Status

- [ ] Configuration: COMPLETE
- [ ] Single task: PENDING
- [ ] Multiple tasks: PENDING
- [ ] Comparison: PENDING
- [ ] AWS deployment: NOT STARTED (per instructions)

---

**Remember**: This is for LOCAL TESTING ONLY. Do not deploy to AWS yet.

**Next Document**: After testing, see `GPT_CODEX_CONFIGURATION_SUMMARY.md` for analysis
