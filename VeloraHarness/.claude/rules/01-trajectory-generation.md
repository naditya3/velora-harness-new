# Trajectory Generation Guidelines

**Purpose:** Ensure successful trajectory generation with OpenHands
**Last Updated:** 2026-01-23

---

## **The Correct Script**

**Always use:**
```bash
evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh
```

**NEVER use:**
- ❌ `evaluation/benchmarks/swe_bench/run_infer.py` - Different evaluation approach
- ❌ Custom scripts - Use standardized pipeline
- ❌ Manual step-by-step - Script handles everything

---

## **Script Usage**

### **Basic Usage:**
```bash
cd ~/SWETEs7/OpenHands  # Or VeloraHarness after Poetry fix

./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh \
  MODEL_CONFIG \
  DATASET_PATH \
  EVAL_LIMIT \
  MAX_ITERATIONS \
  NUM_WORKERS
```

### **Parameters:**

1. **MODEL_CONFIG** (required)
   - `llm.gpt` - GPT model
   - `llm.claude` - Claude model
   - `llm.kimi` - Kimi model
   - `llm.qwen` - Qwen model (Bedrock proxy)

2. **DATASET_PATH** (required)
   - **MUST be absolute path:** `/home/ubuntu/dataset.jsonl`
   - **NOT relative:** `~/dataset.jsonl` ❌
   - **NOT tilde:** `$HOME/dataset.jsonl` ❌

3. **EVAL_LIMIT** (optional, default: 1)
   - Number of tasks to process
   - Use `1` for testing
   - Use actual count for production

4. **MAX_ITERATIONS** (optional, default: 30)
   - `30` for quick testing
   - `200` for standard evaluation
   - `300` for production

5. **NUM_WORKERS** (optional, default: 1)
   - Always use `1` to avoid Docker conflicts

---

## **Example Commands:**

### **Test Run (1 task, 30 iterations):**
```bash
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh \
  llm.gpt \
  /home/ubuntu/test_dataset.jsonl \
  1 \
  30 \
  1
```

### **Production Run (200 iterations):**
```bash
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh \
  llm.gpt \
  /home/ubuntu/datasets/task_123456.jsonl \
  1 \
  200 \
  1
```

---

## **Required Environment Variables**

**ALWAYS set before running:**

```bash
export DOCKER_BUILDKIT=0                    # CRITICAL: Prevents buildx
export EVAL_DOCKER_IMAGE_PREFIX="mswebench" # Image prefix
export USE_INSTANCE_IMAGE=true              # Use task images
export RUNTIME_CONTAINER_IMAGE="skip"       # Skip pre-built runtime
export LANGUAGE=python                      # Task language
export RUN_WITH_BROWSING=false
export USE_HINT_TEXT=false
```

**The script sets these internally, but verify if issues occur.**

---

## **Expected Timeline**

| Phase | Duration | Description |
|-------|----------|-------------|
| S3 Download | 0-2 min | If image not cached |
| Docker Tagging | <10 sec | Double tagging |
| Runtime Build | 2-3 min | First time only (cached after) |
| Trajectory Gen | 5-15 min | Depends on iterations |
| Evaluation | 2-3 min | Test execution |
| Reports | <10 sec | OpenHands format |
| **TOTAL** | **10-25 min** | Depends on caching |

---

## **Output Structure (Complete)**

```
evaluation/evaluation_outputs/outputs/
└── <dataset_name>-train/
    └── CodeActAgent/
        └── <model>_maxiter_<N>_<eval_note>/
            ├── output.jsonl              ← Trajectory (400KB+)
            ├── metadata.json             ← Run config (1.5KB)
            ├── llm_completions/          ← LLM logs (3MB+)
            │   └── {instance_id}/
            │       └── *.json (30-50 files)
            ├── logs/                     ← Execution logs
            ├── eval_pilot2_output.jsonl  ← Raw evaluation (400KB+)
            └── eval_outputs/             ← OpenHands format
                ├── report.json           ← Aggregate (8KB)
                └── {instance_id}/
                    ├── report.json       ← Instance report (8KB)
                    ├── patch.diff        ← Git patch (varies)
                    └── test_output.txt   ← Test logs (varies)
```

---

## **Troubleshooting**

### **Issue: "ModuleNotFoundError: openhands.agenthub"**

**Cause:** Poetry environment doesn't have openhands installed

**Solution:**
```bash
cd ~/VeloraHarness  # Or OpenHands
poetry install  # Install as editable package
poetry run python -c "import openhands.agenthub; print('OK')"
```

**Alternative:**
Use OpenHands installation instead (has working Poetry env)

---

### **Issue: "docker buildx build failed"**

**Cause:** `docker.py` doesn't have DOCKER_BUILDKIT=0 support

**Solution:**
```bash
# Verify fix is present
grep "Use legacy builder" openhands/runtime/builder/docker.py

# If missing, copy from VeloraHarness
scp VeloraHarness/openhands/runtime/builder/docker.py \
    instance:~/OpenHands/openhands/runtime/builder/
```

---

### **Issue: "Could not find output directory"**

**Cause:** Script's `find` command didn't locate output.jsonl

**Solution:**
Script now searches for `output.jsonl` file first (fixed), but verify:
```bash
# Manual search
find evaluation/evaluation_outputs/outputs -name "output.jsonl" -mmin -30

# If found, script should work
```

---

### **Issue: "Expecting property name enclosed in double quotes"**

**Cause:** `eval_pilot2_standardized.py` using line-by-line JSON parsing

**Solution:**
Verify script has fix at line 575:
```bash
grep "content = f.read" evaluation/benchmarks/multi_swe_bench/scripts/eval_pilot2_standardized.py
```

Should show: `content = f.read().strip()` followed by `dataset = json.loads(content)`

---

## **Pre-flight Checklist**

Before running trajectory generation:

- [ ] All 4 critical files deployed (verify checksums)
- [ ] Dataset file is **absolute path**
- [ ] Docker image available in S3 or locally loaded
- [ ] Poetry environment working (`poetry run python` succeeds)
- [ ] Sufficient disk space (50GB+ free)
- [ ] No other evaluations running (check `ps aux | grep run_infer`)

---

## **Success Criteria**

A successful run should produce:

- [ ] `output.jsonl` exists (>100KB)
- [ ] Git patch in output.jsonl (>10KB)
- [ ] `metadata.json` exists
- [ ] `llm_completions/` directory with 20+ JSON files
- [ ] `eval_pilot2_output.jsonl` exists
- [ ] `eval_outputs/report.json` created
- [ ] `eval_outputs/{instance_id}/report.json` created
- [ ] `eval_outputs/{instance_id}/patch.diff` extracted
- [ ] `eval_outputs/{instance_id}/test_output.txt` saved
- [ ] No errors in script output

---

## **Common Mistakes to Avoid**

1. ❌ Using relative paths for dataset (`~/file.jsonl`)
2. ❌ Running in wrong directory (must be in OpenHands or VeloraHarness root)
3. ❌ Using `swe_bench` instead of `multi_swe_bench`
4. ❌ Interrupting script mid-execution
5. ❌ Not verifying all 4 critical files deployed
6. ❌ Running without Poetry environment setup

---

## **Log Files**

Script outputs to stdout/stderr. Capture with:

```bash
./run_full_eval_with_s3.sh ... 2>&1 | tee ~/trajectory_run.log
```

**Monitor progress:**
```bash
tail -f ~/trajectory_run.log
```

**Check for errors:**
```bash
grep -i "error\|failed\|traceback" ~/trajectory_run.log
```

---

## **If Script Fails**

1. **Check logs** for exact error
2. **Verify critical fixes** (checksums match)
3. **Check disk space** (`df -h /`)
4. **Check Docker** (`docker ps`, `docker images`)
5. **Verify Poetry** (`poetry run python -c "import openhands"`)
6. **Review this guide** for known issues

**DO NOT:**
- ❌ Manually run phases separately
- ❌ Create custom scripts
- ❌ Skip verification steps
- ❌ Modify critical files without updating checksums

---

## **Reference Documents**

- `00-critical-fixes.md` - Critical code that must be maintained
- `02-deployment.md` - How to deploy to instances
- `03-evaluation.md` - Evaluation-specific guidelines

**For detailed technical info:** See `OPENHANDS_VELORA_HARNESS_MEMORY.md`
