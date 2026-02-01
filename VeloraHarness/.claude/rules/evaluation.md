---
paths:
  - "evaluation/**/*.py"
  - "evaluation/**/*.sh"
---

# SWE-Bench Evaluation Rules

## Evaluation Pipeline

1. **Trajectory Generation** (`run_infer.py`)
   - Generates agent actions and git patches
   - Output: `output.jsonl` with `git_patch` field

2. **Patch Evaluation** (`eval_infer.py`)
   - Applies patches to task repository
   - Runs test suite
   - Output: `output.swebench_eval.jsonl`

## Critical Parameters

- `--eval-n-limit` - Number of tasks to evaluate (use 1 for testing)
- `--max-iterations` - Max agent iterations (300 for xhigh, 100 for normal)
- `--eval-num-workers` - Parallel workers (use 1 for xhigh reasoning)

## Output Structure

```
evaluation_outputs/outputs/<dataset>/<agent>/<model>_maxiter_N_run_X/
├── output.jsonl              # Trajectory with git_patch
├── output.swebench_eval.jsonl # Evaluation results
├── metadata.json             # Run configuration
├── llm_completions/          # Raw LLM responses
└── eval_outputs/             # Per-instance eval logs
```

## Never Do

- Don't set `eval-num-workers > 1` with xhigh reasoning
- Don't reuse runtime images across different tasks
- Don't skip the `DOCKER_BUILDKIT=0` environment variable
- Don't hardcode API keys in scripts (use config.toml)
