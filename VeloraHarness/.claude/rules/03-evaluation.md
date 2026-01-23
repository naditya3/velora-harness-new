# Evaluation Guidelines

**Purpose:** Evaluation-specific rules and best practices
**Last Updated:** 2026-01-23

---

## **Two Evaluation Approaches**

### **Approach 1: Full Pipeline (Trajectory + Evaluation)**

**Use when:** Need to generate trajectory from scratch

**Script:** `run_full_eval_with_s3.sh`

**Process:**
1. Downloads Docker image from S3
2. Generates trajectory (Phase 1)
3. Evaluates trajectory (Phase 2)
4. Creates reports (Phase 3)

**Timeline:** 10-25 minutes per task

---

### **Approach 2: Evaluation Only (Existing Trajectory)**

**Use when:** Already have trajectory, just need evaluation

**Script:** Direct call to `eval_pilot2_standardized.py`

**Process:**
```bash
python3 evaluation/benchmarks/multi_swe_bench/scripts/eval_pilot2_standardized.py \
  --trajectory-file /path/to/output.jsonl \
  --dataset-file /path/to/dataset.jsonl \
  --docker-image mswebench/sweb.eval.x86_64.{instance_id}:latest \
  --output-file /path/to/result.jsonl \
  --timeout 600
```

**Timeline:** 2-3 minutes per task

---

## **eval_pilot2_standardized.py Requirements**

### **Input Files:**

**1. Trajectory File** (output.jsonl)
- Must contain: `instance_id`, `test_result.git_patch`, `history`
- Format: Single JSON object (formatted or compact)
- Size: Typically 100KB - 10MB

**2. Dataset File** (dataset.jsonl)
- Must contain: `instance_id`, `FAIL_TO_PASS`, `PASS_TO_PASS`, `test_patches`, `test_command`, `test_output_parser`
- Format: Single JSON object (NOT JSONL - this was the bug!)
- Size: Typically 5KB - 50KB

**3. Docker Image**
- Must be loaded and tagged as `mswebench/sweb.eval.x86_64.{instance_id}:latest`
- Must contain repository code at `/app/repo`
- Must have environment setup at `/saved/ENV` or `/saved/*/ENV`

---

### **Parameters:**

```
--trajectory-file   Path to output.jsonl (ABSOLUTE PATH)
--dataset-file      Path to dataset.jsonl (ABSOLUTE PATH)
--docker-image      Docker image name (with tag)
--output-file       Where to save results (ABSOLUTE PATH)
--timeout           Test timeout in seconds (default: 600)
```

---

### **Process:**

1. **Load Files**
   - Parse trajectory as single JSON
   - Parse dataset as single JSON
   - Extract instance_id, git_patch, test lists

2. **Start Docker Container**
   - From specified image
   - Mount necessary volumes
   - Set up environment

3. **Apply Model Patch**
   - Extract git_patch from trajectory
   - Apply to `/app/repo` in container
   - Verify apply succeeded

4. **Reset Test Files**
   - Restore test files to clean state
   - Prevents contamination from model changes

5. **Apply Golden Test Patches**
   - Parse `test_patches` from dataset (expects 5 patches)
   - Apply each patch in sequence
   - Verify all patches apply cleanly

6. **Run Tests**
   - Source environment: `source /saved/ENV` or `source /saved/*/ENV`
   - Execute test command from dataset
   - Capture all output

7. **Parse Results**
   - Use parser from `test_output_parser` field
   - Extract PASSED/FAILED/ERROR tests
   - Map to F2P and P2P categories

8. **Generate Report**
   - Calculate resolution (all F2P passed)
   - Count test results
   - Save to output file

---

## **Output Format**

```json
{
  "instance_id": "1319603449576684",
  "model": "gpt-5.1",
  "test_result": { "git_patch": "..." },
  "history": [...],
  "pilot2_eval_details": {
    "instance_id": "1319603449576684",
    "resolved": false,
    "failed_apply_patch": false,
    "failed_apply_test_patch": false,
    "error_eval": false,
    "test_timeout": false,
    "tests_passed": 101,
    "tests_failed": 3,
    "tests_error": 21,
    "fail_to_pass_success": [],
    "fail_to_pass_failed": ["test1", "test2", "test3"],
    "pass_to_pass_success": ["test4", "test5", ...],
    "pass_to_pass_failed": [],
    "test_output": "===== test session starts ====...",
    "error_message": ""
  },
  "resolved": false
}
```

---

## **Client Harness Requirements**

### **Working Directory:**
```bash
cd /app/repo
```
All commands run from repository root inside container.

### **Environment Setup:**
```bash
source /saved/ENV 2>/dev/null || source /saved/*/ENV 2>/dev/null || true
```
Sources environment variables (Python path, dependencies, etc.)

### **Test Command:**
From dataset's `test_command` field, typically:
```bash
pytest --no-header -rA --tb=no -p no:cacheprovider -x tests/
```

### **Test Parsers:**

**pytest_v3 (most common):**
- Looks for: `PASSED`, `FAILED`, `ERROR` markers
- Format: `tests/test_file.py::TestClass::test_name PASSED`

**unittest:**
- Looks for: `OK`, `FAIL`, `ERROR` in output
- Format: `test_name (module.TestClass) ... ok`

---

## **Docker Image Requirements**

### **Must Have:**
1. Repository code at `/app/repo`
2. Environment file at `/saved/ENV` or `/saved/*/ENV`
3. Python environment with dependencies installed
4. Test framework (pytest or unittest)

### **Image Naming:**
- **From S3:** `{repo_underscore}-{commit}.tar`
- **Loaded as:** `vmvm-registry.fbinfra.net/repomate_image_activ_{framework}/{repo}:{commit}`
- **Tagged as:**
  - `mswebench/sweb.eval.x86_64.{instance_id}:latest`
  - `mswebench/{repo_m}:pr-{instance_id}`

---

## **Success Criteria**

**Evaluation succeeds when:**

✅ **Patch applies cleanly**
- `failed_apply_patch: false`

✅ **Test patches apply**
- `failed_apply_test_patch: false`
- All 5 golden test patches applied

✅ **Tests run**
- `tests_passed + tests_failed + tests_error > 0`
- Test output not empty

✅ **Results parsed**
- F2P and P2P lists populated
- Test counts accurate

**Resolved = true when:**
- All F2P tests pass
- All P2P tests pass

---

## **Common Issues**

### **Issue: "failed_apply_patch: true"**

**Causes:**
- Model patch has syntax errors
- Patch targets non-existent files
- Patch context doesn't match

**Impact:** Cannot evaluate, tests don't run

---

### **Issue: "test_timeout: true"**

**Causes:**
- Tests hang (infinite loops, network calls)
- Tests take >600 seconds

**Solution:**
- Increase `--timeout` parameter
- Or mark as legitimate timeout

---

### **Issue: "tests_passed = 0, tests_failed = 0, tests_error = 0"**

**Causes:**
- Test command failed before running tests
- Parser couldn't find test markers
- Test environment crashed

**Common causes:**
- Model patch broke imports
- Missing dependencies
- Python syntax errors

---

### **Issue: "error_eval: true"**

**Causes:**
- Docker container failed to start
- Dataset file not found
- Trajectory file corrupted
- Docker image not loaded

**Solution:**
- Check error_message field
- Verify all inputs exist
- Verify Docker image loaded

---

## **Batch Evaluation**

**For processing multiple trajectories:**

### **Using run_batch_eval_single_instance.py:**

```bash
cd /Users/macbookpro/Desktop/SWETEs7/Harness

python3 run_batch_eval_single_instance.py eval1
```

**Process:**
1. Reads assignments from `instance_assignments.json`
2. Groups by task (3 models per task)
3. For each task:
   - Upload dataset once
   - Download Docker image once
   - Evaluate all 3 models
   - Prune Docker image
4. Collect results locally

**Timeline:** ~12 min per task (4 min download + 8 min eval)

---

## **Statistics from Phase 7**

**Success Rate:** 98% (513/521 with tests executed)

**Failures (8 total):**
- 6 model patch errors (broke test environment)
- 2 timeouts (tests >900 seconds)

**All failures were legitimate model issues, not evaluation script bugs.**

---

## **Best Practices**

### **DO:**
- ✅ Use absolute paths for all file arguments
- ✅ Verify Docker image loaded before evaluation
- ✅ Check dataset has required fields
- ✅ Set timeout appropriate for test suite size
- ✅ Clean up Docker images after evaluation

### **DON'T:**
- ❌ Use relative or tilde paths (`~/file.jsonl`)
- ❌ Modify eval_pilot2_standardized.py without testing
- ❌ Run multiple evaluations on same instance simultaneously
- ❌ Skip Docker cleanup (leads to disk full)
- ❌ Assume failures are script bugs (usually model issues)

---

## **Reference Files**

- **Evaluation script:** `eval_pilot2_standardized.py` (33KB, checksum: c71b963...)
- **Parser implementations:** Lines 100-250 in eval_pilot2_standardized.py
- **Test results:** `/Users/macbookpro/Desktop/SWETEs7/Harness/batch_eval_outputs/`
- **Analysis:** `/Users/macbookpro/Desktop/SWETEs7/Harness/docs/8_FAILURES_ANALYSIS.md`
