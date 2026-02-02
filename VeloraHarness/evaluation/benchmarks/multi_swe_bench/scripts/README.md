# VeloraHarness Evaluation Scripts

This directory contains scripts for running complete evaluation pipelines in VeloraHarness. These scripts combine trajectory generation with detailed patch evaluation to produce comprehensive results.

## Table of Contents

- [Overview](#overview)
- [Available Scripts](#available-scripts)
- [When to Use Which Script](#when-to-use-which-script)
- [Prerequisites](#prerequisites)
- [Usage Examples](#usage-examples)
- [Output Structure](#output-structure)
- [Environment Variables](#environment-variables)
- [Troubleshooting](#troubleshooting)

---

## Overview

VeloraHarness evaluation consists of two phases:

1. **Trajectory Generation**: The agent interacts with the codebase to solve the issue and generates a patch
2. **Patch Evaluation**: The patch is applied and tested in an isolated Docker environment

The scripts in this directory automate both phases and produce standardized evaluation reports compatible with SWE-bench and OpenHands formats.

---

## Available Scripts

### 1. `run_full_eval_with_s3.sh`

**Full evaluation pipeline with S3 Docker image download**

- Downloads Docker images from S3 based on dataset configuration
- Loads and tags images for OpenHands
- Runs complete evaluation pipeline
- **Best for**: AWS environments, CI/CD pipelines, first-time task evaluations

### 2. `run_full_eval_local_docker.sh` ⭐ NEW

**Full evaluation pipeline with local Docker images**

- Uses Docker images already available locally
- No S3 download required
- Same evaluation pipeline and output structure
- **Best for**: Development, repeated evaluations, offline environments

### 3. `run_full_eval.sh` / `run_full_eval_fixed.sh`

**Legacy evaluation scripts**

- Older versions with various fixes
- May not have all latest improvements
- **Recommended**: Use the S3 or local Docker versions above

### 4. `run_velora_infer.sh`

**Trajectory generation only**

- Runs only Phase 1 (trajectory generation)
- Does not perform patch evaluation
- **Use when**: You only need to generate patches without testing

---

## When to Use Which Script

### Use `run_full_eval_with_s3.sh` when:

- ✅ Running evaluations on AWS with S3 access
- ✅ Evaluating a task for the first time (no local Docker image)
- ✅ Setting up CI/CD pipelines
- ✅ You want automatic image download and setup
- ❌ You're offline or don't have S3 credentials
- ❌ You're repeatedly evaluating the same task (inefficient to re-download)

### Use `run_full_eval_local_docker.sh` when:

- ✅ Docker images are already built/downloaded locally
- ✅ Running multiple evaluations on the same task
- ✅ Development and testing workflows
- ✅ You're offline or prefer not to use S3
- ✅ You want faster evaluation cycles
- ❌ You don't have the Docker image locally yet

### Quick Decision Tree

```
Do you have the Docker image locally?
├─ YES → Use run_full_eval_local_docker.sh
└─ NO
   ├─ Do you have S3 access?
   │  ├─ YES → Use run_full_eval_with_s3.sh
   │  └─ NO → Build the image first, then use run_full_eval_local_docker.sh
   └─ Or use run_velora_infer.sh (trajectory only, no evaluation)
```

---

## Prerequisites

### Common Requirements (All Scripts)

1. **Poetry environment** with VeloraHarness installed
2. **Docker** installed and running
3. **Configuration file**: `config.toml` with LLM settings
4. **Dataset file**: JSONL file with task specification

### Additional for S3 Script

5. **AWS CLI** configured with credentials
6. **S3 access** to `s3://kuberha-velora/velora-files/images/`

### Additional for Local Docker Script

5. **Docker image** loaded locally (via `docker load` or `docker build`)

---

## Usage Examples

### Basic Usage

All scripts follow the same parameter structure:

```bash
./script_name.sh MODEL_CONFIG DATASET [EVAL_LIMIT] [MAX_ITER] [NUM_WORKERS] [AGENT]
```

**Parameters:**

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `MODEL_CONFIG` | ✅ | - | LLM config from config.toml (e.g., `llm.gpt`, `llm.claude`) |
| `DATASET` | ✅ | - | Path to task JSONL file |
| `EVAL_LIMIT` | ❌ | 1 | Number of tasks to evaluate |
| `MAX_ITER` | ❌ | 30 | Maximum agent iterations |
| `NUM_WORKERS` | ❌ | 1 | Number of parallel workers |
| `AGENT` | ❌ | CodeActAgent | Agent class to use |

### Example 1: Evaluate with S3 Download

```bash
cd /path/to/VeloraHarness

# Evaluate single task with GPT model
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh \
  llm.gpt \
  data/tasks/python__mypy-11220.jsonl \
  1 \
  30 \
  1
```

### Example 2: Evaluate with Local Docker

```bash
cd /path/to/VeloraHarness

# Ensure Docker image exists locally
docker images | grep mswebench

# Run evaluation
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_local_docker.sh \
  llm.claude \
  data/tasks/python__mypy-11220.jsonl \
  1 \
  50 \
  1
```

### Example 3: High-Iteration Evaluation

```bash
# Allow more agent iterations for complex tasks
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_local_docker.sh \
  llm.gpt \
  data/tasks/complex_task.jsonl \
  1 \
  100 \
  1
```

### Example 4: Multiple Tasks in Parallel

```bash
# Evaluate 5 tasks with 3 parallel workers
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh \
  llm.kimi \
  data/tasks/batch.jsonl \
  5 \
  30 \
  3
```

### Example 5: Custom Agent

```bash
# Use a different agent class
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_local_docker.sh \
  llm.claude \
  data/tasks/python__mypy-11220.jsonl \
  1 \
  30 \
  1 \
  CustomAgent
```

---

## Output Structure

Both scripts produce identical output structures:

```
evaluation/evaluation_outputs/outputs/
└── multi_swe_bench/
    └── {agent}/{model}/{eval_note}/
        └── {timestamp}/
            ├── output.jsonl           ← Main trajectory file with patch
            ├── metadata.json          ← Run configuration metadata
            ├── llm_completions/       ← LLM API responses
            │   └── {instance_id}/
            │       └── *.json
            └── eval_outputs/          ← Evaluation results
                └── {instance_id}/
                    ├── report.json    ← Test results (OpenHands format)
                    ├── patch.diff     ← Applied git patch
                    ├── test_output.txt ← Full test execution output
                    └── run_instance.log ← Container execution log
```

### Key Files Explained

#### `output.jsonl`
Main trajectory file containing:
- Agent's conversation history
- Final patch in `test_result.git_patch`
- Trajectory metadata

#### `eval_outputs/{instance_id}/report.json`
Standardized test results in OpenHands format:
```json
{
  "instance_id": {
    "patch_is_None": false,
    "patch_exists": true,
    "patch_successfully_applied": true,
    "resolved": true,
    "tests_status": {
      "FAIL_TO_PASS": {
        "success": ["test1", "test2"],
        "failure": []
      },
      "PASS_TO_PASS": {
        "success": ["test3", "test4"],
        "failure": []
      }
    }
  }
}
```

#### `test_output.txt`
Complete output from test execution, including:
- Test framework output (pytest/unittest)
- Pass/fail status for each test
- Error messages and stack traces

---

## Environment Variables

### Critical Variables (Already Set in Scripts)

These are pre-configured in the scripts and should not be changed:

```bash
export DOCKER_BUILDKIT=0                    # Prevents buildx failures
export EVAL_DOCKER_IMAGE_PREFIX="mswebench" # Docker image prefix
export USE_INSTANCE_IMAGE=true              # Use instance-specific images
export LANGUAGE=python                      # Task language
export RUN_WITH_BROWSING=false              # Disable browser
export USE_HINT_TEXT=false                  # Disable hints
```

### Optional Variables (Can Be Set Before Running)

```bash
# Number of evaluation runs (default: 1)
export N_RUNS=3

# Custom experiment name (appended to eval_note)
export EXP_NAME="my_experiment"

# OpenHands version (auto-detected if not set)
export OPENHANDS_VERSION="v1.1.0"
```

### Example with Custom Variables

```bash
# Run evaluation 3 times with custom experiment name
export N_RUNS=3
export EXP_NAME="ablation_study"

./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_local_docker.sh \
  llm.gpt \
  data/tasks/python__mypy-11220.jsonl
```

---

## Troubleshooting

### Common Issues and Solutions

#### 1. Docker Image Not Found

**Error:**
```
ERROR: Expected Docker image not found: mswebench/...
```

**Solutions:**

For S3 script:
```bash
# Check S3 access
aws s3 ls s3://kuberha-velora/velora-files/images/

# Verify AWS credentials
aws sts get-caller-identity
```

For local Docker script:
```bash
# Check if image exists
docker images | grep mswebench

# If not, either:
# Option 1: Download and load from S3
aws s3 cp s3://kuberha-velora/velora-files/images/{image}.tar ./
docker load < {image}.tar

# Option 2: Build the image
# (Follow SWE-bench Docker build instructions)

# Option 3: Use the S3 script instead
./run_full_eval_with_s3.sh ...
```

#### 2. Output File Not Found

**Error:**
```
ERROR: Could not find output.jsonl!
```

**Solutions:**
```bash
# Check if trajectory generation succeeded
ls -la evaluation/evaluation_outputs/outputs/

# Look for recent output files
find evaluation/evaluation_outputs/outputs/ -name "output.jsonl" -mmin -60

# Check for errors in trajectory generation
# Look at the logs above the error message
```

#### 3. Evaluation Script Not Found

**Error:**
```
ERROR: Evaluation script not found: eval_pilot2_standardized.py
```

**Solutions:**
```bash
# Verify script location
ls -la evaluation/benchmarks/multi_swe_bench/scripts/eval_pilot2_standardized.py

# If missing, ensure you're in the correct directory
pwd  # Should be VeloraHarness root

# Run from correct location
cd /path/to/VeloraHarness
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_local_docker.sh ...
```

#### 4. No Patch Generated

**Output:**
```
WARNING: No valid patch found in output. Skipping evaluation.
```

**This is normal if:**
- Agent couldn't solve the issue within MAX_ITER iterations
- Agent encountered errors during execution
- Task is particularly challenging

**Solutions:**
```bash
# Increase iterations
./run_full_eval_local_docker.sh llm.gpt task.jsonl 1 100 1

# Try a different model
./run_full_eval_local_docker.sh llm.claude task.jsonl 1 50 1

# Check trajectory for errors
cat {output_dir}/output.jsonl | jq .
```

#### 5. Docker Permission Errors

**Error:**
```
permission denied while trying to connect to the Docker daemon socket
```

**Solutions:**
```bash
# Add user to docker group (Linux)
sudo usermod -aG docker $USER
newgrp docker

# Or run with sudo (not recommended for production)
sudo ./run_full_eval_local_docker.sh ...

# macOS: Ensure Docker Desktop is running
open -a Docker
```

#### 6. Poetry Not Found

**Error:**
```
poetry: command not found
```

**Solutions:**
```bash
# Install poetry
curl -sSL https://install.python-poetry.org | python3 -

# Or use pip
pip install poetry

# Activate virtual environment
cd /path/to/VeloraHarness
poetry install
poetry shell
```

---

## Differences Between S3 and Local Versions

| Aspect | S3 Version | Local Version |
|--------|------------|---------------|
| **Docker Image Source** | Downloads from S3 | Uses local images |
| **Internet Required** | Yes (for S3 access) | No (once image is loaded) |
| **First-Time Setup** | Automatic | Manual image setup |
| **Speed** | Slower (download time) | Faster (no download) |
| **AWS Credentials** | Required | Not required |
| **Repeated Evaluations** | Re-downloads each time | Reuses local image |
| **Image Verification** | Downloads if missing | Prompts user if missing |
| **Use Case** | Production, CI/CD | Development, iteration |

### Code Differences

The only significant differences are in the **Docker Image Management** section:

**S3 Version:**
```bash
# Downloads from S3
aws s3 cp "$S3_PATH" "$S3_IMAGE_FILE"
docker load < "$S3_IMAGE_FILE"
rm -f "$S3_IMAGE_FILE"
```

**Local Version:**
```bash
# Verifies local image exists
if docker images --format "..." | grep -q "^${IMAGE_URI}$"; then
  echo "✓ Docker image found locally"
else
  echo "WARNING: Expected Docker image not found"
  # Prompts user for action
fi
```

Everything else (trajectory generation, evaluation, report generation) is **identical**.

---

## Advanced Usage

### Running Multiple Experiments

```bash
#!/bin/bash
# batch_eval.sh - Run evaluations with different configurations

TASKS=(
  "data/tasks/task1.jsonl"
  "data/tasks/task2.jsonl"
  "data/tasks/task3.jsonl"
)

MODELS=("llm.gpt" "llm.claude" "llm.kimi")

for task in "${TASKS[@]}"; do
  for model in "${MODELS[@]}"; do
    echo "Evaluating $task with $model"
    ./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_local_docker.sh \
      "$model" \
      "$task" \
      1 \
      30 \
      1
  done
done
```

### Collecting Results

```bash
#!/bin/bash
# collect_results.sh - Aggregate all evaluation results

OUTPUT_BASE="evaluation/evaluation_outputs/outputs"

# Find all report.json files
find "$OUTPUT_BASE" -name "report.json" -path "*/eval_outputs/*" | while read report; do
  instance_id=$(basename $(dirname "$report"))
  resolved=$(cat "$report" | jq -r ".\"$instance_id\".resolved // false")
  echo "$instance_id: $resolved"
done
```

### Debugging Failed Evaluations

```bash
#!/bin/bash
# debug_eval.sh - Get detailed info about a failed evaluation

OUTPUT_DIR=$1

if [ -z "$OUTPUT_DIR" ]; then
  echo "Usage: $0 <output_directory>"
  exit 1
fi

echo "=== Trajectory ==="
cat "$OUTPUT_DIR/output.jsonl" | jq '.history[-5:]'

echo ""
echo "=== Test Output ==="
cat "$OUTPUT_DIR/eval_outputs/"*/test_output.txt | tail -50

echo ""
echo "=== Report ==="
cat "$OUTPUT_DIR/eval_outputs/"*/report.json | jq .
```

---

## Related Documentation

- **VeloraHarness Main README**: `../../README.md`
- **Configuration Guide**: `../../../../config.toml.example`
- **Evaluation Script**: `eval_pilot2_standardized.py`
- **OpenHands Integration**: See `evaluation/benchmarks/multi_swe_bench/`

---

## Support and Contributing

For issues, questions, or contributions:

1. Check this README first
2. Review the troubleshooting section
3. Examine the script source code (well-commented)
4. Check existing issues/documentation

---

## Version History

- **v1.2** (2026-01-29): Added `run_full_eval_local_docker.sh` for local Docker images
- **v1.1** (2025-12): Added `run_full_eval_with_s3.sh` with S3 download support
- **v1.0** (2025-11): Initial evaluation scripts

---

## License

Part of VeloraHarness. See main project license.
