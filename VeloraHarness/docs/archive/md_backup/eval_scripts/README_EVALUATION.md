# Velora Evaluation Pipeline

## 📋 Overview

This directory contains the complete evaluation pipeline for Velora tasks, combining:
1. **Trajectory Generation** - OpenHands agent generates code fixes
2. **Patch Evaluation** - Applies patches and runs tests to verify resolution

## 🔧 Scripts

### 1. `run_full_eval.sh` ⭐ **Recommended**

**Complete end-to-end pipeline:** Generates trajectories AND evaluates patches.

```bash
./run_full_eval.sh MODEL_CONFIG DATASET [EVAL_LIMIT] [MAX_ITER] [NUM_WORKERS] [AGENT]
```

**Parameters:**
- `MODEL_CONFIG`: LLM config (e.g., `llm.gpt`, `llm.claude`, `llm.kimi`)
- `DATASET`: Path to `.jsonl` dataset file
- `EVAL_LIMIT`: Number of tasks to process (default: 1)
- `MAX_ITER`: Maximum agent iterations (default: 200)
- `NUM_WORKERS`: Parallel workers (default: 1)
- `AGENT`: Agent class (default: `CodeActAgent`)

**Example:**
```bash
# Full evaluation of 1 task with GPT
./run_full_eval.sh llm.gpt ~/datasets/task_12rambau_sepal_ui.jsonl 1 200 1
```

**Output Structure:**
```
evaluation/evaluation_outputs/outputs/<hash>/
├── output.jsonl              ← Trajectory + git patch
├── metadata.json             ← Run metadata
├── llm_completions/          ← LLM response history
├── logs/                     ← Agent logs
├── eval_summary.json         ← Overall evaluation summary
└── eval_outputs/             ← Per-task evaluation results
    └── <instance_id>/
        ├── patch.diff        ← Extracted git patch
        ├── report.json       ← Resolution status
        ├── test_output.txt   ← Full test output
        ├── run_instance.log  ← Detailed execution log
        └── eval.sh           ← Test command used
```

---

### 2. `run_velora_infer.sh`

**Trajectory generation only** (faster, for batch runs without evaluation).

```bash
./run_velora_infer.sh MODEL_CONFIG DATASET [EVAL_LIMIT] [MAX_ITER] [NUM_WORKERS]
```

**Use when:**
- You want to generate trajectories quickly
- Evaluation will be run separately later
- Batch processing multiple tasks

**Example:**
```bash
# Generate 10 trajectories with Claude
./run_velora_infer.sh llm.claude ~/datasets/batch_10_tasks.jsonl 10 200 2
```

---

### 3. `simple_eval.py`

**Standalone evaluation** of existing trajectory output.

```bash
python3 simple_eval.py \
    --input-file path/to/output.jsonl \
    --dataset path/to/dataset.jsonl \
    --timeout 600
```

**Use when:**
- You already have trajectory outputs
- You want to re-evaluate with different settings
- Debugging evaluation issues

**Example:**
```bash
# Evaluate existing trajectory
python3 simple_eval.py \
    --input-file evaluation_outputs/.../output.jsonl \
    --dataset ~/datasets/task.jsonl
```

---

## 🚀 Quick Start

### Prerequisites

1. **Docker images loaded and tagged:**
   ```bash
   # Download from S3
   aws s3 cp s3://kuberha-velora/velora-files/images/12rambau_sepal_ui-<commit>.tar /tmp/
   
   # Load image
   docker load -i /tmp/12rambau_sepal_ui-<commit>.tar
   
   # Double-tag for OpenHands compatibility
   docker tag <loaded_image> mswebench/sweb.eval.x86_64.<instance_id>:latest
   docker tag <loaded_image> mswebench/12rambau_m_sepal_ui:pr-<instance_id>
   ```

2. **Environment variables set:**
   ```bash
   export DOCKER_BUILDKIT=0                # CRITICAL!
   export EVAL_DOCKER_IMAGE_PREFIX=mswebench
   export USE_INSTANCE_IMAGE=true
   ```

3. **Dataset prepared:**
   ```bash
   # Ensure dataset is in JSONL format with required fields:
   # - instance_id
   # - repo
   # - base_commit
   # - problem_statement
   # - test_command
   # - fail_to_pass_tests
   # - pass_to_pass_tests
   ```

### Run a Single Task

```bash
# Navigate to OpenHands/VeloraHarness root
cd ~/SWETEs7/OpenHands  # or VeloraHarness

# Activate Poetry environment
poetry shell

# Run full evaluation
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval.sh \
    llm.gpt \
    ~/datasets/task_1319603449576684.jsonl \
    1 \
    200 \
    1
```

---

## 📊 Understanding the Output

### Phase 1: Trajectory Generation

The agent will:
1. Read the problem statement
2. Explore the codebase
3. Make code changes
4. Generate a git patch

**Success indicators:**
- ✅ `git_patch` field is non-empty in `output.jsonl`
- ✅ Patch size > 1KB (substantial changes)
- ✅ No `TmuxCommandNotFound` errors

### Phase 2: Patch Evaluation

The evaluation will:
1. Apply the patch to the Docker container
2. Run the test command
3. Parse test results
4. Check if FAIL_TO_PASS tests now pass

**Success indicators:**
- ✅ `resolved: true` in `report.json`
- ✅ `failed_apply_patch: false`
- ✅ `error_eval: false`
- ✅ Target tests pass

### Reading `report.json`

```json
{
  "resolved": true,              ← Task was successfully resolved
  "failed_apply_patch": false,   ← Patch applied cleanly
  "error_eval": false,           ← No evaluation errors
  "f2p_status": {
    "tests/test_ThemeSelect.py::TestThemeSelect::test_init": "PASSED"
  },
  "p2p_status": {
    "tests/test_Alert.py::TestAlert::test_init": "PASSED"
  },
  "total_tests": 2,
  "passed_tests": 2,
  "failed_tests": 0
}
```

### Reading `eval_summary.json`

```json
{
  "total": 1,                    ← Total tasks evaluated
  "resolved": 1,                 ← Successfully resolved
  "failed_apply_patch": 0,       ← Patches that failed to apply
  "error_eval": 0,               ← Evaluation errors
  "resolution_rate": 100.0       ← Success percentage
}
```

---

## 🔧 Advanced Usage

### Batch Processing Multiple Tasks

```bash
# Run 20 tasks with 4 parallel workers
./run_full_eval.sh llm.claude ~/datasets/batch_20.jsonl 20 200 4
```

### Using Different Models

```bash
# GPT-4
./run_full_eval.sh llm.gpt ~/datasets/task.jsonl 1 200 1

# Claude
./run_full_eval.sh llm.claude ~/datasets/task.jsonl 1 200 1

# Kimi
./run_full_eval.sh llm.kimi ~/datasets/task.jsonl 1 200 1

# Qwen
./run_full_eval.sh llm.qwen ~/datasets/task.jsonl 1 200 1
```

### Adjusting Iteration Limits

```bash
# Quick test (50 iterations)
./run_full_eval.sh llm.gpt ~/datasets/task.jsonl 1 50 1

# Standard run (200 iterations)
./run_full_eval.sh llm.gpt ~/datasets/task.jsonl 1 200 1

# Deep exploration (300 iterations)
./run_full_eval.sh llm.gpt ~/datasets/task.jsonl 1 300 1
```

### Re-evaluating Existing Trajectories

```bash
# If you already generated trajectories and want to re-evaluate
python3 simple_eval.py \
    --input-file evaluation_outputs/.../output.jsonl \
    --dataset ~/datasets/task.jsonl \
    --timeout 600
```

---

## 🐛 Troubleshooting

### Issue: `TmuxCommandNotFound` Error

**Cause:** OpenHands runtime missing `tmux` dependency.

**Solution:** The Dockerfile.j2 fix is already applied! Clear old runtime images:
```bash
docker images | grep 'ghcr.io/openhands/runtime' | awk '{print $3}' | xargs docker rmi -f
```

### Issue: Empty `git_patch` Field

**Cause:** Agent failed to complete trajectory or encountered errors.

**Solutions:**
1. Check logs in `<output_dir>/logs/`
2. Increase `MAX_ITER` (try 300)
3. Try a different model
4. Review `llm_completions/` for LLM errors

### Issue: `failed_apply_patch: true`

**Cause:** Git patch conflicts with current codebase.

**Solutions:**
1. Verify Docker image has correct base commit
2. Check if patch contains correct file paths
3. Review `run_instance.log` for apply errors

### Issue: Tests Pass But `resolved: false`

**Cause:** FAIL_TO_PASS tests may not have run or parser failed.

**Solutions:**
1. Check `test_output.txt` for actual test results
2. Verify `test_command` in dataset is correct
3. Review `eval.sh` for the exact command used

### Issue: Docker Permission Errors

**Solution:**
```bash
# Add user to docker group (Linux)
sudo usermod -aG docker $USER
# Then logout and login

# macOS: restart Docker Desktop
```

### Issue: `Cannot find output directory`

**Cause:** Trajectory generation failed or output path changed.

**Solution:**
```bash
# Find recent outputs manually
find evaluation/evaluation_outputs -name "output.jsonl" -type f -mmin -60
```

---

## 📝 Environment Variables

These are automatically set by the scripts, but can be overridden:

```bash
# CRITICAL - Prevents Docker buildx failures
export DOCKER_BUILDKIT=0

# Docker image prefix for your tasks
export EVAL_DOCKER_IMAGE_PREFIX=mswebench

# Use instance-specific Docker images
export USE_INSTANCE_IMAGE=true

# Task language (for evaluation)
export LANGUAGE=python

# Disable browsing and hints for pure coding tasks
export RUN_WITH_BROWSING=false
export USE_HINT_TEXT=false
```

---

## 🎯 Expected Results

### Cost Per Task

- **GPT-4**: ~$0.30 per task
- **Claude**: ~$0.40 per task  
- **Kimi**: ~$0.25 per task
- **Qwen**: ~$0.15 per task

### Time Per Task

- **Trajectory Generation**: 2-5 minutes (depends on iterations)
- **Evaluation**: 30-60 seconds per task
- **Total**: ~3-6 minutes per task

### Git Patch Sizes

- **Simple fixes**: 1-10 KB
- **Standard fixes**: 10-100 KB
- **Complex fixes**: 100+ KB

---

## 🔗 Related Documentation

- **SETUP.md** - Installation and configuration
- **PRE_COMMIT_CHECKLIST.md** - Security and quality checks
- **GITHUB_PUSH_SUMMARY.md** - What's being committed
- **.cursorrules** - Known issues and fixes

---

## 💡 Tips

1. **Start with a single task** to verify your setup before scaling
2. **Use `run_full_eval.sh`** for complete end-to-end testing
3. **Monitor Docker disk space** - clean up regularly with `docker system prune`
4. **Check logs first** when debugging - they contain detailed error info
5. **Increase iterations** if patches are incomplete
6. **Use parallel workers** (2-4) for batch processing to save time

---

## ✅ Success Checklist

Before running at scale, verify:

- [ ] Dockerfile.j2 has the tmux fix (line 48)
- [ ] `DOCKER_BUILDKIT=0` is set
- [ ] Docker images are loaded and double-tagged
- [ ] Dataset is in correct JSONL format
- [ ] `config.toml` has valid API keys
- [ ] Single task test passes with `resolved: true`
- [ ] Enough disk space (20GB+ free recommended)

---

**You're ready to run the full evaluation pipeline!** 🚀

Start with a single task to verify everything works, then scale to your full dataset.

