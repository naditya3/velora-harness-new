# Quick Start: GPT-5.2-codex Testing

## Prerequisites
- [ ] OpenAI API key with GPT-5.2-codex access
- [ ] Docker installed and running
- [ ] Python environment set up

## Step 1: Add API Key (1 minute)

Edit `config.toml`:
```bash
# Find this line:
api_key = "YOUR_OPENAI_API_KEY_HERE"

# Replace with:
api_key = "sk-your-actual-key-here"
```

## Step 2: Verify Configuration (30 seconds)

```bash
cd /Users/macbookpro/Documents/SWE_Bench/Velora_SWE_Harness/VeloraHarness
python test_gpt_codex_config_simple.py
```

✅ Should see: "Configuration Test: PASSED"

## Step 3: Run First Test (5-10 minutes)

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

## What to Check

### During Execution
- [ ] Agent initializes without errors
- [ ] API calls succeed (no auth errors)
- [ ] Docker container starts properly

### After Completion
- [ ] Check output in eval output directory
- [ ] Review LLM completion logs: `llm_completions/*/gpt-5.2-codex-*.json`
- [ ] Verify `reasoning_effort: "high"` in API calls
- [ ] Check task completion status

## Common Issues

| Issue | Solution |
|-------|----------|
| "Invalid API key" | Check config.toml has correct key |
| "Model not found" | Verify GPT-5.2-codex access |
| Docker error | Ensure Docker is running |
| Import errors | Check Python environment |

## Key Configuration

```toml
[llm.gpt_codex]
model = "gpt-5.2-codex"
reasoning_effort = "high"    # medium, high, or xhigh
temperature = 0.2            # 0.0-1.0
max_iterations = 200         # in [core] section
```

## Success Criteria
- [x] Configuration validates
- [ ] First task completes without errors
- [ ] API calls show reasoning_effort parameter
- [ ] Output patch is generated

## Next: Full Documentation
See `GPT52_CODEX_SETUP.md` for complete documentation
