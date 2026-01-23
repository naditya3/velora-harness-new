# Critical Fixes - MUST MAINTAIN

**Priority:** CRITICAL
**Last Verified:** 2026-01-23

---

## **Fix #1: DOCKER_BUILDKIT=0 Support**

**File:** `openhands/runtime/builder/docker.py`
**Lines:** 129-139
**Checksum:** `c719fdafa6102198c8068f530846cac3`

**Required Code:**
```python
# Use legacy builder if DOCKER_BUILDKIT=0 is set
use_buildx = os.environ.get('DOCKER_BUILDKIT', '1') != '0'

if use_buildx:
    buildx_cmd.extend(['buildx', 'build'])
else:
    buildx_cmd.append('build')  # CRITICAL: Use regular docker build
```

**Why Critical:**
- OpenHands runtime build ALWAYS fails with buildx on AWS instances
- Setting `DOCKER_BUILDKIT=0` environment variable is not enough
- Code must check the variable and use regular `docker build` command
- Without this: 100% failure rate for trajectory generation

**Verification:**
```bash
grep -A 10 "Use legacy builder" openhands/runtime/builder/docker.py
```

---

## **Fix #2: tmux in Dockerfile Template**

**File:** `openhands/runtime/utils/runtime_templates/Dockerfile.j2`
**Lines:** 41-48
**Checksum:** `6edc931ce32b967dd50dc91d7f08551f`

**Required Code:**
```dockerfile
{% if (('ubuntu' in base_image) or ('mswebench' in base_image)) %}
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        wget curl ca-certificates sudo apt-utils git jq tmux build-essential ...
```

**Why Critical:**
- OpenHands requires `tmux` for bash session management
- mswebench images don't have tmux by default
- Without this: Runtime containers crash with `TmuxCommandNotFound`
- This was the difference between December 2025 success and January 2026 failures

**Verification:**
```bash
grep "tmux" openhands/runtime/utils/runtime_templates/Dockerfile.j2
```

---

## **Fix #3: Dataset Parsing**

**File:** `evaluation/benchmarks/multi_swe_bench/scripts/eval_pilot2_standardized.py`
**Lines:** 572-580
**Checksum:** `c71b963ae19398e900681ec2340da445`

**Required Code:**
```python
# Load dataset
with open(dataset_file, 'r') as f:
    # Datasets are single JSON objects (formatted or compact), not JSONL
    # Just read and parse the entire file
    content = f.read().strip()
    dataset = json.loads(content)
```

**NEVER use:**
```python
# BROKEN - expects JSONL format
for line in f:
    dataset = json.loads(line)  # FAILS on formatted JSON
```

**Why Critical:**
- Datasets are formatted JSON (pretty-printed), not JSONL
- Line-by-line parsing fails on line 2 with "Expecting property name"
- Fixed 192 evaluation failures (73% → 98% success rate)

**Verification:**
```bash
grep -A 3 "content = f.read" evaluation/benchmarks/multi_swe_bench/scripts/eval_pilot2_standardized.py | grep "dataset = json.loads(content)"
```

---

## **Fix #4: AST-based List Parsing**

**File:** `evaluation/benchmarks/multi_swe_bench/scripts/eval_pilot2_standardized.py`
**Lines:** 586-611

**Required Code:**
```python
import ast

def _parse_list_field(value):
    """Parse a list field that may be JSON, Python literal, or already a list."""
    if isinstance(value, list):
        return value
    # Try JSON first
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        pass
    # Fallback to Python literal (handles single quotes)
    try:
        parsed = ast.literal_eval(value)
        if isinstance(parsed, list):
            return parsed
    except (ValueError, SyntaxError):
        pass
    return []
```

**Why Critical:**
- Some datasets use Python literal syntax: `['test1', 'test2']` (single quotes)
- JSON parser fails on single quotes
- AST handles both JSON and Python literal formats

**Verification:**
```bash
grep -A 5 "_parse_list_field" evaluation/benchmarks/multi_swe_bench/scripts/eval_pilot2_standardized.py | grep "ast.literal_eval"
```

---

## **Deployment Verification Checklist**

Before deploying to any instance, verify ALL 4 fixes:

```bash
# Check docker.py has DOCKER_BUILDKIT=0 support
[ "$(md5 -r openhands/runtime/builder/docker.py | cut -d' ' -f1)" = "c719fdafa6102198c8068f530846cac3" ] && echo "✓ docker.py correct" || echo "✗ docker.py MISMATCH"

# Check Dockerfile.j2 has tmux
[ "$(md5 -r openhands/runtime/utils/runtime_templates/Dockerfile.j2 | cut -d' ' -f1)" = "6edc931ce32b967dd50dc91d7f08551f" ] && echo "✓ Dockerfile.j2 correct" || echo "✗ Dockerfile.j2 MISMATCH"

# Check eval_pilot2_standardized.py has fixes
[ "$(md5 -r evaluation/benchmarks/multi_swe_bench/scripts/eval_pilot2_standardized.py | cut -d' ' -f1)" = "c71b963ae19398e900681ec2340da445" ] && echo "✓ eval_pilot2_standardized.py correct" || echo "✗ eval_pilot2_standardized.py MISMATCH"

# Check run_full_eval_with_s3.sh exists
[ "$(md5 -r evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh | cut -d' ' -f1)" = "fe08d93ed67b76c21e59b9d84e07ba36" ] && echo "✓ run_full_eval_with_s3.sh correct" || echo "✗ run_full_eval_with_s3.sh MISMATCH"
```

---

## **DO NOT:**

❌ Use `evaluation/benchmarks/swe_bench/` - Use `multi_swe_bench` instead
❌ Modify these files without updating checksums in this document
❌ Remove any of these fixes when merging upstream OpenHands updates
❌ Deploy to instances without verifying all 4 checksums match

---

## **Emergency Recovery:**

If fixes are lost, restore from:
```
/Users/macbookpro/Documents/SWE_Bench/Velora_SWE_Harness/VeloraHarness/
```

All 4 files have verified checksums as of 2026-01-23.
