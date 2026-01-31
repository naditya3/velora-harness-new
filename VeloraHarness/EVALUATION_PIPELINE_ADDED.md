# Evaluation Pipeline - Added to VeloraHarness

## 📋 What Was Added

### ✅ Complete Evaluation Scripts

Four new files have been added to provide a complete end-to-end evaluation pipeline:

```
evaluation/benchmarks/multi_swe_bench/scripts/
├── run_full_eval.sh        ⭐ Complete pipeline (trajectory + evaluation)
├── run_velora_infer.sh     📝 Trajectory generation only
├── simple_eval.py          🔧 Standalone evaluation script
└── README_EVALUATION.md    📚 Complete documentation
```

---

## 🎯 Purpose

These scripts enable you to:

1. **Generate AI trajectories** - OpenHands agent solves coding tasks
2. **Evaluate patches** - Apply generated fixes and run tests
3. **Get detailed results** - JSON reports with resolution status

**All in one command!**

---

## 🚀 Quick Start Example

### Single Task Test

```bash
# Navigate to VeloraHarness
cd /Users/macbookpro/Documents/SWE_Bench/Velora_SWE_Harness/VeloraHarness

# Activate Poetry environment
poetry shell

# Set critical environment variables
export DOCKER_BUILDKIT=0
export EVAL_DOCKER_IMAGE_PREFIX=mswebench
export USE_INSTANCE_IMAGE=true

# Run full evaluation on 1 task
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval.sh \
    llm.gpt \
    ~/datasets/task_1319603449576684.jsonl \
    1 \
    200 \
    1
```

**Expected Output:**
```
============================================
VELORA FULL EVALUATION PIPELINE
============================================
PHASE 1: TRAJECTORY GENERATION
  → Generating git patch...
  ✅ Patch generated: 67.5 KB

PHASE 2: PATCH EVALUATION
  → Applying patch...
  → Running tests...
  ✅ RESOLVED!

=== EVALUATION SUMMARY ===
Total: 1
Resolved: 1
Failed Apply: 0
Errors: 0
```

---

## 📊 Output Structure

```
evaluation/evaluation_outputs/outputs/<hash>/
├── output.jsonl              ← Trajectory + git patch
├── metadata.json             ← Run metadata
├── llm_completions/          ← LLM response history
├── logs/                     ← Agent logs
├── eval_summary.json         ← Overall evaluation summary
└── eval_outputs/             ← Per-task evaluation results
    └── 1319603449576684/
        ├── patch.diff        ← Extracted git patch
        ├── report.json       ← Resolution status ⭐
        ├── test_output.txt   ← Full test output
        ├── run_instance.log  ← Detailed execution log
        └── eval.sh           ← Test command used
```

### Key File: `report.json`

```json
{
  "resolved": true,              ← ✅ Task successfully resolved!
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

---

## 🔧 Three Ways to Use

### 1. Full Evaluation (Recommended)

**Use:** Complete pipeline - generates trajectory AND evaluates patch

```bash
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval.sh \
    llm.gpt \
    ~/datasets/task.jsonl \
    1 \      # Number of tasks
    200 \    # Max iterations
    1        # Workers
```

**When to use:**
- You want complete results
- You need to know if the fix actually works
- Production runs

---

### 2. Trajectory Only (Faster)

**Use:** Just generate patches, skip evaluation

```bash
./evaluation/benchmarks/multi_swe_bench/scripts/run_velora_infer.sh \
    llm.gpt \
    ~/datasets/task.jsonl \
    10 \     # Can do more tasks faster
    200 \
    2        # Can use more workers
```

**When to use:**
- Batch processing many tasks
- You'll evaluate later
- Testing different models quickly

---

### 3. Evaluate Existing Trajectories

**Use:** Re-evaluate previously generated trajectories

```bash
python3 ./evaluation/benchmarks/multi_swe_bench/scripts/simple_eval.py \
    --input-file evaluation_outputs/.../output.jsonl \
    --dataset ~/datasets/task.jsonl \
    --timeout 600
```

**When to use:**
- You already have trajectory outputs
- Debugging evaluation issues
- Testing different evaluation settings

---

## 🎓 Real-World Example

### Scenario: Test the sepal_ui task

**Prerequisites:**
```bash
# 1. Docker image already loaded and tagged
docker images | grep "12rambau_m_sepal_ui"

# 2. Dataset exists
ls ~/datasets/task_1319603449576684.jsonl

# 3. Environment variables set
export DOCKER_BUILDKIT=0
export EVAL_DOCKER_IMAGE_PREFIX=mswebench
export USE_INSTANCE_IMAGE=true
```

**Run:**
```bash
cd /Users/macbookpro/Documents/SWE_Bench/Velora_SWE_Harness/VeloraHarness

poetry shell

./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval.sh \
    llm.gpt \
    ~/datasets/task_1319603449576684.jsonl \
    1 \
    200 \
    1
```

**Expected:**
- ✅ **Cost:** ~$0.30
- ✅ **Time:** ~3-5 minutes
- ✅ **Patch Size:** ~67 KB
- ✅ **Resolution:** `resolved: true`

---

## 🔗 Integration with Existing Workflow

### Before (Manual Process)

```bash
# Step 1: Generate trajectory manually
poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py ...

# Step 2: Extract patch manually
cat output.jsonl | jq '.test_result.git_patch' > patch.diff

# Step 3: Apply patch manually in Docker
docker run ... git apply patch.diff

# Step 4: Run tests manually
docker exec ... pytest

# Step 5: Parse results manually
# (painful!)
```

### After (Automated)

```bash
# One command does everything!
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval.sh \
    llm.gpt ~/datasets/task.jsonl 1 200 1

# Results in standardized JSON format
cat eval_outputs/*/report.json
```

---

## 🌟 Key Features

1. **✅ Automated End-to-End**
   - No manual steps required
   - Consistent output format
   - Error handling built-in

2. **✅ Detailed Results**
   - Per-test status (PASSED/FAILED)
   - Full test output saved
   - Execution logs for debugging

3. **✅ Production-Ready**
   - Handles errors gracefully
   - Timeout protection
   - Clean Docker lifecycle

4. **✅ Flexible Usage**
   - Run full pipeline or individual steps
   - Support for all LLM models
   - Configurable workers and iterations

5. **✅ Comprehensive Documentation**
   - README with examples
   - Troubleshooting guide
   - Expected outputs documented

---

## 📝 Git Status

### Files to Commit

```bash
git add evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval.sh
git add evaluation/benchmarks/multi_swe_bench/scripts/run_velora_infer.sh
git add evaluation/benchmarks/multi_swe_bench/scripts/simple_eval.py
git add evaluation/benchmarks/multi_swe_bench/scripts/README_EVALUATION.md
git add EVALUATION_PIPELINE_ADDED.md

git commit -m "feat: Add complete evaluation pipeline

- run_full_eval.sh: End-to-end trajectory + evaluation
- run_velora_infer.sh: Trajectory generation only
- simple_eval.py: Standalone evaluation script
- README_EVALUATION.md: Complete documentation

Enables automated testing of AI-generated code fixes with
detailed JSON reports and standardized output format."

git push origin main
```

---

## ✅ Verification Checklist

Before pushing to GitHub, verify:

- [ ] All 4 files are staged
- [ ] Scripts are executable (`chmod +x *.sh`)
- [ ] No secrets in scripts (API keys, etc.)
- [ ] README is comprehensive
- [ ] Scripts reference correct paths
- [ ] Environment variables documented

---

## 🎯 What Your Teammate Gets

When your teammate clones the repo, they'll have:

1. **Complete evaluation pipeline** ready to use
2. **Clear documentation** with examples
3. **Three flexible approaches** depending on needs
4. **Standardized output format** for easy parsing
5. **Production-ready scripts** with error handling

They just need to:
1. Follow `SETUP.md` to install dependencies
2. Load Docker images
3. Run `run_full_eval.sh`
4. Get results in `report.json`

---

## 🚀 Next Steps

### For Local Testing

```bash
# 1. Test with a single task
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval.sh \
    llm.gpt ~/datasets/test_task.jsonl 1 200 1

# 2. Review output
cat evaluation_outputs/.../eval_outputs/*/report.json

# 3. If successful, scale up!
```

### For AWS Deployment

```bash
# 1. Copy scripts to AWS instances
rsync -avz evaluation/benchmarks/multi_swe_bench/scripts/ \
    ubuntu@aws-instance:~/VeloraHarness/evaluation/benchmarks/multi_swe_bench/scripts/

# 2. Run remotely
ssh aws-instance './VeloraHarness/evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval.sh llm.gpt ~/datasets/task.jsonl 1 200 1'

# 3. Download results
scp -r ubuntu@aws-instance:~/VeloraHarness/evaluation_outputs/ ./
```

### For Batch Processing (200 Tasks)

```bash
# Use master pipeline (if available) or run in batches
for batch in task_{1..200}.jsonl; do
    ./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval.sh \
        llm.gpt ~/datasets/$batch 1 200 1
done
```

---

## 🎉 Summary

You now have a **complete, production-ready evaluation pipeline** that:

- ✅ Works with the Dockerfile.j2 fix
- ✅ Generates detailed JSON reports
- ✅ Handles errors gracefully
- ✅ Supports all LLM models
- ✅ Scales from 1 to 200+ tasks
- ✅ Is fully documented

**Ready to commit and share with your team!** 🚀

