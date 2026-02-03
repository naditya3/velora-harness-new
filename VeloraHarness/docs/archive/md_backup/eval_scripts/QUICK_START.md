# Quick Start Guide - VeloraHarness Evaluation Scripts

## 5-Minute Quick Start

### Step 1: Choose Your Script

**Have Docker image locally?** → Use `run_full_eval_local_docker.sh`
**Need to download from S3?** → Use `run_full_eval_with_s3.sh`

### Step 2: Run Evaluation

```bash
cd /path/to/VeloraHarness

# With local Docker:
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_local_docker.sh \
  llm.gpt \
  data/tasks/python__mypy-11220.jsonl

# Or with S3:
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh \
  llm.gpt \
  data/tasks/python__mypy-11220.jsonl
```

### Step 3: Check Results

```bash
# Results are in: evaluation/evaluation_outputs/outputs/
find evaluation/evaluation_outputs/outputs/ -name "report.json" -path "*/eval_outputs/*"
```

---

## Common Scenarios

### Scenario 1: First Time Evaluation

```bash
# Use S3 script - it downloads and sets up everything
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh \
  llm.gpt \
  data/tasks/my_task.jsonl \
  1 \
  30 \
  1
```

### Scenario 2: Re-running Same Task

```bash
# Use local script - faster, no download needed
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_local_docker.sh \
  llm.claude \
  data/tasks/my_task.jsonl \
  1 \
  50 \
  1
```

### Scenario 3: High-Iteration Evaluation

```bash
# Allow 100 iterations for complex tasks
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_local_docker.sh \
  llm.gpt \
  data/tasks/complex_task.jsonl \
  1 \
  100 \
  1
```

### Scenario 4: Batch Evaluation

```bash
# Evaluate 10 tasks with 3 parallel workers
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh \
  llm.kimi \
  data/tasks/batch_tasks.jsonl \
  10 \
  30 \
  3
```

---

## Parameter Reference

```bash
./script.sh MODEL DATASET [LIMIT] [ITERS] [WORKERS] [AGENT]
            ↓     ↓       ↓       ↓       ↓        ↓
            │     │       │       │       │        └─ Agent type (default: CodeActAgent)
            │     │       │       │       └────────── Parallel workers (default: 1)
            │     │       │       └────────────────── Max iterations (default: 30)
            │     │       └────────────────────────── Task limit (default: 1)
            │     └────────────────────────────────── Path to task JSONL
            └──────────────────────────────────────── LLM config (e.g., llm.gpt)
```

### Examples

```bash
# Single task, 30 iterations, 1 worker
./run_full_eval_local_docker.sh llm.gpt task.jsonl

# Single task, 50 iterations, 1 worker
./run_full_eval_local_docker.sh llm.gpt task.jsonl 1 50

# 5 tasks, 30 iterations, 2 workers
./run_full_eval_local_docker.sh llm.gpt batch.jsonl 5 30 2

# Single task, 100 iterations, 1 worker, custom agent
./run_full_eval_local_docker.sh llm.gpt task.jsonl 1 100 1 CustomAgent
```

---

## Pre-flight Checklist

Before running evaluation, ensure:

- [ ] **Poetry environment** is set up (`poetry install`)
- [ ] **Docker** is running (`docker ps`)
- [ ] **config.toml** has your LLM API keys
- [ ] **Dataset file** exists and is valid JSON
- [ ] **Working directory** is VeloraHarness root
- [ ] (S3 only) **AWS credentials** are configured
- [ ] (Local only) **Docker image** is loaded locally

### Quick Checks

```bash
# 1. Check you're in VeloraHarness root
pwd  # Should end in /VeloraHarness

# 2. Check Docker is running
docker ps

# 3. Check config exists
ls -l config.toml

# 4. Check dataset exists
ls -l data/tasks/*.jsonl

# 5. (Local only) Check Docker images
docker images | grep mswebench

# 6. (S3 only) Check AWS access
aws s3 ls s3://kuberha-velora/velora-files/images/ | head
```

---

## What Happens During Evaluation

### Phase 1: Setup (5-30 seconds)
- Validates parameters
- Extracts image info from dataset
- Downloads (S3) or verifies (local) Docker image
- Tags image for OpenHands

### Phase 2: Trajectory Generation (2-10 minutes)
- Agent interacts with codebase
- Attempts to solve the issue
- Generates patch
- Saves trajectory to output.jsonl

### Phase 3: Patch Evaluation (1-5 minutes)
- Applies patch in Docker container
- Runs test suite
- Collects test results
- Generates reports

### Total Time
- **S3**: ~8-45 minutes (including download)
- **Local**: ~3-15 minutes (no download)

---

## Understanding Results

### Success Indicators

```bash
# Look for these in output:
✓ Docker image found locally
✓ Image tagged successfully
Instance ID verified: python__mypy-11220
Git patch size: 1234 bytes
Resolved: True
Tests Passed: 15
Tests Failed: 0
F2P Success: 3/3
P2P Success: 12/12
SUCCESS: Full evaluation complete
```

### Result Files

```
evaluation/evaluation_outputs/outputs/.../
└── eval_outputs/
    └── python__mypy-11220/
        ├── report.json          ← START HERE
        ├── patch.diff           ← Generated patch
        ├── test_output.txt      ← Test details
        └── run_instance.log     ← Execution log
```

### Reading report.json

```bash
# Quick check if task was resolved
cat report.json | jq '.["python__mypy-11220"].resolved'
# Output: true or false

# See which tests passed
cat report.json | jq '.["python__mypy-11220"].tests_status.FAIL_TO_PASS.success'
# Output: ["test_1", "test_2", ...]

# Full formatted output
cat report.json | jq .
```

---

## Troubleshooting

### Problem: "Docker image not found"

```bash
# For local script:
docker images | grep mswebench  # Check if it exists

# If not found, use S3 script instead:
./run_full_eval_with_s3.sh llm.gpt task.jsonl
```

### Problem: "Output file not found"

```bash
# Check if trajectory generation succeeded:
find evaluation/evaluation_outputs/outputs/ -name "output.jsonl" -mmin -60

# If found, check for errors in the output above
```

### Problem: "No patch generated"

This is normal if agent couldn't solve the issue. Try:
```bash
# Increase iterations
./run_full_eval_local_docker.sh llm.gpt task.jsonl 1 100 1

# Or try different model
./run_full_eval_local_docker.sh llm.claude task.jsonl 1 50 1
```

### Problem: "AWS credentials not found" (S3 only)

```bash
# Configure AWS CLI
aws configure

# Or set environment variables
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_DEFAULT_REGION="us-east-1"
```

### Problem: "Poetry not found"

```bash
# Install poetry
curl -sSL https://install.python-poetry.org | python3 -

# Restart shell, then:
cd /path/to/VeloraHarness
poetry install
poetry shell
```

---

## Tips & Tricks

### Speed Up Repeated Evaluations

```bash
# First run: download image
./run_full_eval_with_s3.sh llm.gpt task.jsonl

# Subsequent runs: use local (faster)
./run_full_eval_local_docker.sh llm.gpt task.jsonl
```

### Run Multiple Experiments

```bash
# Test different iteration counts
for iters in 30 50 100; do
  ./run_full_eval_local_docker.sh llm.gpt task.jsonl 1 $iters 1
done
```

### Compare Different Models

```bash
# Test multiple models on same task
for model in llm.gpt llm.claude llm.kimi; do
  ./run_full_eval_local_docker.sh $model task.jsonl 1 30 1
done
```

### Collect All Results

```bash
# Find all resolved instances
find evaluation/evaluation_outputs/outputs/ -name "report.json" -path "*/eval_outputs/*" | \
  xargs grep -l '"resolved": true'
```

---

## Next Steps

1. **Read full documentation**: `README.md`
2. **Compare scripts**: `SCRIPT_COMPARISON.md`
3. **Customize config**: `../../../../config.toml`
4. **Check evaluation script**: `eval_pilot2_standardized.py`

---

## Getting Help

1. Check `README.md` troubleshooting section
2. Verify all prerequisites
3. Check script comments (well-documented)
4. Review example output structures

---

**Happy Evaluating!** 🚀
