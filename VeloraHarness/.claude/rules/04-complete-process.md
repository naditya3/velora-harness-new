# Complete Process - End-to-End Workflow

**Purpose:** Step-by-step guide for complete trajectory + evaluation workflow
**Last Updated:** 2026-01-23
**Verified:** ✅ Tested on eval1 (2026-01-23)

---

## **Prerequisites**

### **1. Code Consistency**

Verify all instances have correct files:
```bash
cd /Users/macbookpro/Documents/SWE_Bench/Velora_SWE_Harness/VeloraHarness
./scripts/verify_consistency.sh eval1 eval2 eval3 ...
```

**Must show:** ✓ for all 4 critical files on each instance

---

### **2. Dataset Preparation**

**Dataset must include:**
```json
{
  "instance_id": "1319603449576684",
  "repo": "12rambau/sepal_ui",
  "base_commit": "97371fba...",
  "image_storage_uri": "vmvm-registry.fbinfra.net/...",
  "FAIL_TO_PASS": ["test1", "test2", "test3"],
  "PASS_TO_PASS": ["test4", "test5", ...],
  "test_patches": ["patch1", "patch2", ...],
  "test_command": "pytest ...",
  "test_output_parser": "python/parse_log_pytest_v3",
  "problem_statement": "..."
}
```

**Format:** Single JSON object (formatted or compact, NOT JSONL)

---

### **3. Docker Image in S3**

**Image must exist at:**
```
s3://kuberha-velora/velora-files/images/{repo_underscore}-{commit}.tar
```

**Example:**
```
s3://kuberha-velora/velora-files/images/12rambau_sepal_ui-97371fbaed444727126a2969cd68f856db77221f.tar
```

---

## **Complete Workflow**

### **Step 1: Upload Dataset**

```bash
# From local machine
scp /path/to/dataset.jsonl aws-instance-eval1:/home/ubuntu/dataset.jsonl
```

---

### **Step 2: Run Complete Pipeline**

```bash
ssh aws-instance-eval1

cd ~/SWETEs7/OpenHands
export PATH="$HOME/.local/bin:$PATH"

# Run complete pipeline (all 3 phases)
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh \
  llm.gpt \
  /home/ubuntu/dataset.jsonl \
  1 \
  200 \
  1 \
  2>&1 | tee ~/trajectory_run.log
```

**What happens:**
1. Downloads Docker image from S3 (~2.9GB)
2. Tags Docker image (double tagging)
3. **Phase 1:** Trajectory generation (5-15 min)
4. **Phase 2:** Evaluation (2-3 min)
5. **Phase 3:** Report generation (<1 min)

**Expected completion:** 10-25 minutes

---

### **Step 3: Verify Output**

```bash
# On instance
cd ~/SWETEs7/OpenHands

# Find output directory
OUTPUT_DIR=$(find evaluation/evaluation_outputs/outputs -name "output.jsonl" -mmin -30 | head -1 | xargs dirname)

echo "Output: $OUTPUT_DIR"

# Verify structure
ls -lR "$OUTPUT_DIR/" | head -50

# Check key files
[ -f "$OUTPUT_DIR/output.jsonl" ] && echo "✓ output.jsonl" || echo "✗ MISSING"
[ -f "$OUTPUT_DIR/eval_pilot2_output.jsonl" ] && echo "✓ eval_pilot2_output.jsonl" || echo "✗ MISSING"
[ -d "$OUTPUT_DIR/eval_outputs" ] && echo "✓ eval_outputs/" || echo "✗ MISSING"
[ -f "$OUTPUT_DIR/eval_outputs/report.json" ] && echo "✓ report.json" || echo "✗ MISSING"
```

---

### **Step 4: Download Results**

```bash
# From local machine
rsync -avz "aws-instance-eval1:$OUTPUT_DIR/" ./local_output/

# Verify locally
ls -lR ./local_output/
```

---

### **Step 5: Validate Results**

```bash
# Check trajectory
cat ./local_output/output.jsonl | python3 -c "
import json, sys
d = json.load(sys.stdin)
patch = d.get('test_result', {}).get('git_patch', '')
print(f'Instance: {d.get(\"instance_id\")}')
print(f'History: {len(d.get(\"history\", []))} entries')
print(f'Git patch: {len(patch)} bytes')
print('✓ Valid trajectory' if len(patch) > 100 else '✗ No patch')
"

# Check evaluation
cat ./local_output/eval_pilot2_output.jsonl | python3 -c "
import json, sys
d = json.load(sys.stdin)
det = d.get('pilot2_eval_details', {})
print(f'Resolved: {det.get(\"resolved\")}')
print(f'Tests: {det.get(\"tests_passed\")} passed, {det.get(\"tests_failed\")} failed')
print(f'F2P: {len(det.get(\"fail_to_pass_success\", []))}/{len(det.get(\"fail_to_pass_failed\", []))+len(det.get(\"fail_to_pass_success\", []))}')
print(f'P2P: {len(det.get(\"pass_to_pass_success\", []))}/{len(det.get(\"pass_to_pass_failed\", []))+len(det.get(\"pass_to_pass_success\", []))}')
"

# Check OpenHands report
cat ./local_output/eval_outputs/report.json | python3 -m json.tool | head -30
```

---

## **Expected Output (Verified)**

### **Files Created:**

```
output.jsonl                                    405KB   ✅
metadata.json                                   1.5KB   ✅
llm_completions/{instance_id}/*.json           ~3MB    ✅
eval_pilot2_output.jsonl                       437KB   ✅
eval_outputs/report.json                       8.3KB   ✅
eval_outputs/{instance_id}/report.json         8.3KB   ✅
eval_outputs/{instance_id}/patch.diff          68KB    ✅
eval_outputs/{instance_id}/test_output.txt     13KB    ✅
```

### **Test Results (Example from eval1):**

```
Instance: 1319603449576684
Model: GPT (gpt-5.1-2025-11-13)
Runtime: 18:52 minutes
Git patch: 68,370 bytes
History: 80 entries
Tests: 101 passed, 3 failed, 21 errors
F2P: 0/3 (not resolved)
P2P: 99/99 (all passed)
```

---

## **Batch Processing**

### **For Multiple Tasks:**

Create assignment file mapping instances to tasks:
```json
{
  "eval1": [
    {
      "instance_id": "123...",
      "model": "gpt",
      "dataset_file": "/path/to/dataset.jsonl",
      "task_name": "repo__repo-instance"
    }
  ]
}
```

**Run batch script:**
```bash
cd /Users/macbookpro/Desktop/SWETEs7/Harness
python3 run_batch_eval_single_instance.py eval1
```

---

## **Quality Assurance**

### **After Each Run:**

1. ✅ Verify `output.jsonl` has git_patch (>100 bytes)
2. ✅ Check `eval_outputs/` directory created
3. ✅ Verify `report.json` has test results
4. ✅ Confirm `patch.diff` extracted
5. ✅ Review `test_output.txt` for errors

### **Success Metrics:**

**Good trajectory:**
- Git patch: 1KB - 100KB
- History entries: 20 - 200
- No errors in output.jsonl

**Good evaluation:**
- Tests executed: >0
- Test output not empty
- F2P/P2P lists populated
- No critical errors

**Resolution not required:**
- Task can have `resolved: false` (model didn't fix all tests)
- This is expected and valid
- Still counts as successful evaluation

---

## **Common Failure Scenarios**

### **Scenario 1: Runtime Build Fails**

**Symptoms:**
```
docker buildx build ... returned non-zero exit status 1
```

**Cause:** Missing DOCKER_BUILDKIT=0 fix in docker.py

**Fix:**
```bash
# Copy fixed docker.py
scp VeloraHarness/openhands/runtime/builder/docker.py \
    instance:~/SWETEs7/OpenHands/openhands/runtime/builder/
```

---

### **Scenario 2: Trajectory Generated but Evaluation Fails**

**Symptoms:**
```
Parsed 0 test results
tests_passed: 0, tests_failed: 0, tests_error: 0
```

**Causes:**
- Test environment crashed
- Model patch broke imports
- Docker image missing dependencies

**This is VALID:** Model failure, not evaluation bug

---

### **Scenario 3: Script Exits After Phase 1**

**Symptoms:**
```
ERROR: Could not find output.jsonl!
```

**Cause:** Directory finding logic failed (now fixed)

**Fix:** Use updated run_full_eval_with_s3.sh (lines 285-306)

---

## **Performance Optimization**

### **Docker Image Caching:**

- First run: Downloads from S3 (~2 min for 2.9GB)
- Subsequent runs: Uses cached image (instant)
- Clean cache: `docker rmi {image}` to force re-download

### **Runtime Image Caching:**

- First run: Builds runtime (~2-3 min)
- Subsequent runs: Reuses cached runtime (saves 2-3 min)
- Runtime cached per: `oh_v{version}_{hash}`

### **Parallel Execution:**

**DO NOT run multiple instances on same AWS instance** - Docker conflicts

**DO run on multiple AWS instances simultaneously:**
```bash
# Run all 10 instances in parallel
for i in eval1 eval2 ... lancer3; do
  ssh aws-instance-$i "./run_script.sh ..." &
done
wait
```

---

## **Verification Commands**

### **Check if instance ready:**
```bash
ssh aws-instance-eval1 bash << 'EOF'
# 1. Files present
[ -f ~/SWETEs7/OpenHands/evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh ] && echo "✓ Script" || echo "✗ Script missing"

# 2. Poetry works
cd ~/SWETEs7/OpenHands
poetry run python -c "import openhands.agenthub" && echo "✓ Poetry" || echo "✗ Poetry broken"

# 3. Docker running
docker ps > /dev/null && echo "✓ Docker" || echo "✗ Docker issue"

# 4. Disk space
df -h / | awk 'NR==2 {if ($5+0 < 80) print "✓ Disk OK"; else print "✗ Disk low"}'

# 5. No running evals
pgrep -f run_infer > /dev/null && echo "⚠ Evaluation running" || echo "✓ No conflicts"
EOF
```

---

## **Next Steps After Verification**

1. ✅ Verified on eval1
2. Deploy to remaining 9 instances
3. Test on one more instance (eval2 or lancer1)
4. Create Phase 8 assignments (79 missing trajectories)
5. Run production batch
6. Collect and consolidate results

---

## **Related Rules**

- Read `00-critical-fixes.md` first to understand what fixes exist
- Read `01-trajectory-generation.md` for script usage details
- Read `02-deployment.md` for deployment procedures
- Read `03-evaluation.md` for evaluation-specific info

---

**This document provides the complete verified workflow from start to finish.**
