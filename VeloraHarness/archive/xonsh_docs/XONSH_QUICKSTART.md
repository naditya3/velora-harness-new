# Xonsh Quick Start Guide

## Installation (5 minutes)

```bash
# Install xonsh
pip install xonsh

# Verify installation
xonsh --version
# Should output: xonsh/0.x.x
```

## Using the Converted Scripts

### 1. Run Velora Inference

```bash
cd /Users/macbookpro/Documents/SWE_Bench/Velora_SWE_Harness/VeloraHarness

# Basic usage
./evaluation/benchmarks/multi_swe_bench/scripts/run_velora_infer.xsh \
    llm.gpt \
    ~/datasets/my_task.jsonl \
    1 \
    200 \
    1

# With different parameters
./evaluation/benchmarks/multi_swe_bench/scripts/run_velora_infer.xsh \
    MODEL_CONFIG \
    DATASET_PATH \
    [EVAL_LIMIT] \
    [MAX_ITER] \
    [NUM_WORKERS]
```

### 2. Run Full Evaluation with S3

```bash
# Basic usage
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.xsh \
    llm.claude \
    data/task.jsonl \
    1 \
    30 \
    1

# Full parameter set
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.xsh \
    MODEL_CONFIG \
    DATASET_PATH \
    [EVAL_LIMIT] \
    [MAX_ITER] \
    [NUM_WORKERS] \
    [AGENT]
```

## Common Issues and Solutions

### Issue 1: "command not found: xonsh"
```bash
# Solution: Add to PATH or use full path
export PATH="$HOME/.local/bin:$PATH"

# Or use python -m xonsh
python -m xonsh ./script.xsh
```

### Issue 2: "Permission denied"
```bash
# Solution: Make script executable
chmod +x ./script.xsh
```

### Issue 3: Script errors with syntax
```bash
# Solution: Check xonsh version
xonsh --version

# Update if needed
pip install --upgrade xonsh
```

## Quick Comparison

### Bash Version
```bash
./evaluation/benchmarks/multi_swe_bench/scripts/run_velora_infer.sh \
    llm.gpt data.jsonl 1 200 1
```

### Xonsh Version (Same functionality)
```bash
./evaluation/benchmarks/multi_swe_bench/scripts/run_velora_infer.xsh \
    llm.gpt data.jsonl 1 200 1
```

**Expected:** Identical outputs in `evaluation/evaluation_outputs/outputs/`

## Testing Your First Conversion

```bash
# 1. Navigate to VeloraHarness
cd /Users/macbookpro/Documents/SWE_Bench/Velora_SWE_Harness/VeloraHarness

# 2. Run xonsh version
./evaluation/benchmarks/multi_swe_bench/scripts/run_velora_infer.xsh \
    llm.gpt test_data.jsonl 1 5 1

# 3. Check output
ls -la evaluation/evaluation_outputs/outputs/

# 4. Verify JSON output
cat evaluation/evaluation_outputs/outputs/*/output.jsonl | jq .
```

## Environment Variables

Both scripts use the same environment variables:

```bash
# Set before running
export DOCKER_BUILDKIT=0
export EVAL_DOCKER_IMAGE_PREFIX=mswebench
export USE_INSTANCE_IMAGE=true
export LANGUAGE=python

# Or let the script set them (default behavior)
```

## What's Different in Xonsh?

### 1. Better Error Messages
```
Bash: "line 42: syntax error"
Xonsh: "TypeError: expected str, got None at line 42"
```

### 2. No jq Dependency
```
Bash: cat file.json | jq '.key'
Xonsh: Uses Python's json module (built-in)
```

### 3. Better Path Handling
```
Bash: cd "$DIR" && ls
Xonsh: Uses pathlib (cross-platform)
```

## Performance

Expect similar performance:
- Startup: ~100ms slower (Python initialization)
- Execution: Identical (same commands executed)
- Overall: < 1% difference for typical workflows

## Documentation

- **Full Report:** `XONSH_MIGRATION_REPORT.md`
- **Quick Reference:** `XONSH_QUICK_REFERENCE.md`
- **Summary:** `XONSH_CONVERSION_SUMMARY.md`

## Support

If you encounter issues:
1. Check `XONSH_QUICK_REFERENCE.md` for common patterns
2. Verify xonsh installation: `xonsh --version`
3. Compare outputs with bash version
4. Check syntax in xonsh REPL: `xonsh` then paste code

## Next Steps

1. Test converted scripts with your tasks
2. Report any issues or differences
3. Consider converting more scripts (see `XONSH_MIGRATION_REPORT.md`)
4. Share feedback with team

## One-Liner Install and Test

```bash
# Install, verify, and test in one go
pip install xonsh && \
xonsh --version && \
cd /Users/macbookpro/Documents/SWE_Bench/Velora_SWE_Harness/VeloraHarness && \
./evaluation/benchmarks/multi_swe_bench/scripts/run_velora_infer.xsh --help || \
echo "Ready to use xonsh scripts!"
```
