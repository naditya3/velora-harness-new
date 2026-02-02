---
name: run-eval
description: Run SWE-bench evaluation with specified LLM config and dataset
disable-model-invocation: true
allowed-tools: Bash, Read, Grep
argument-hint: <llm-config> <dataset-path> [limit]
---

# Run SWE-Bench Evaluation

Run a trajectory generation + evaluation pipeline.

## Arguments
- `$1` - LLM config name (e.g., `llm.gpt_codex`, `llm.gemini`, `llm.claude`)
- `$2` - Path to dataset JSONL file
- `$3` - (Optional) Number of tasks to evaluate (default: 1)

## Prerequisites Check
Before running, verify:
1. Docker is running: `docker ps`
2. Environment variables set: `DOCKER_BUILDKIT=0`
3. Config exists: Check `config.toml` has the specified LLM section

## Execution Steps

1. **Set environment variables**
```bash
export DOCKER_BUILDKIT=0
export EVAL_DOCKER_IMAGE_PREFIX=mswebench
export USE_INSTANCE_IMAGE=true
```

2. **Run trajectory generation**
```bash
cd /home/ec2-user/Jeager/Velora_SWE_Harness/VeloraHarness

poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent-cls CodeActAgent \
    --llm-config $1 \
    --max-iterations 300 \
    --eval-num-workers 1 \
    --dataset $2 \
    --split train \
    --eval-n-limit ${3:-1}
```

3. **Monitor progress**
- Watch for "Container started" messages
- Check for LLM completion files in output directory
- Look for `reasoning_tokens` in logs (should be high for xhigh)

4. **Report results**
After completion, show:
- Output directory path
- Number of successful completions
- Any errors encountered

## Example Usage
```
/run-eval llm.gpt_codex /home/ec2-user/Jeager/Testing/SWE_Hard/task.jsonl 1
```
