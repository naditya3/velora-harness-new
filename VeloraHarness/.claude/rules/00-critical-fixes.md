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

## **Fix #5: build_vscode.py (Required for Poetry Install)**

**File:** `build_vscode.py`
**Location:** VeloraHarness root directory
**Source:** Copy from OpenHands

**Required Code:** (114 lines - Poetry build script)

**Why Critical:**
- Poetry install expects this build script
- Without it: `poetry install` fails with "can't open file 'build_vscode.py'"
- With `SKIP_VSCODE_BUILD=1`: Script runs but skips VSCode extension build
- Allows Poetry to install local openhands/ package as editable

**Solution:**
```bash
cp /path/to/OpenHands/build_vscode.py /path/to/VeloraHarness/
export SKIP_VSCODE_BUILD=1
poetry install  # Now succeeds
```

**Verification:**
```bash
[ -f build_vscode.py ] && echo "✓ build_vscode.py exists" || echo "✗ MISSING"
```

---

## **Fix #6: Git Repository (Required for Metadata)**

**Requirement:** VeloraHarness must be initialized as git repository

**Evidence:** `evaluation/utils/shared.py` line 200 (Official OpenHands code)
```python
def make_metadata(...):
    metadata = EvalMetadata(
        ...
        git_commit=subprocess.check_output(['git', 'rev-parse', 'HEAD']),
        ...
    )
```

**Why Critical:**
- No error handling - expects git repo to exist
- Every run records git commit in metadata.json
- Without git: Script fails immediately with "fatal: not a git repository"

**Solution:**
```bash
cd VeloraHarness
git init
git add .
git commit -m "VeloraHarness deployment"
```

**Verification:**
```bash
git rev-parse HEAD && echo "✓ Git repo initialized" || echo "✗ NOT a git repo"
```

---

## **Fix #7: PYTHONPATH (Required for VeloraHarness)**

**Requirement:** PYTHONPATH must include VeloraHarness directory

**Evidence:** Verified on lancer1 fresh test

**Why Critical:**
- Poetry install doesn't add VeloraHarness to sys.path automatically
- Imports work in interactive shell but fail in scripts
- `poetry run python evaluation/...run_infer.py` fails without PYTHONPATH

**Solution:**
```bash
export PYTHONPATH="$(pwd):$PYTHONPATH"
```

**Note:** OpenHands doesn't need this (has proper editable install)

**Verification:**
```bash
poetry run python -c "import sys; print([p for p in sys.path if 'VeloraHarness' in p])"
# Should show VeloraHarness path
```

---

## **Fix #8: datasets Package**

**Requirement:** datasets package must be installed

**Evidence:** Not in poetry.lock, but imported by run_infer.py

**Solution:**
```bash
poetry run pip install datasets
```

**Verification:**
```bash
poetry run python -c "import datasets; print('✓')"
```

---

## **Deployment Verification Checklist**

Before deploying to any instance, verify ALL requirements:

```bash
# Fix #1: docker.py DOCKER_BUILDKIT=0 support
[ "$(md5 -r openhands/runtime/builder/docker.py | cut -d' ' -f1)" = "c719fdafa6102198c8068f530846cac3" ] && echo "✓ docker.py" || echo "✗ docker.py MISMATCH"

# Fix #2: Dockerfile.j2 tmux
[ "$(md5 -r openhands/runtime/utils/runtime_templates/Dockerfile.j2 | cut -d' ' -f1)" = "6edc931ce32b967dd50dc91d7f08551f" ] && echo "✓ Dockerfile.j2" || echo "✗ Dockerfile.j2 MISMATCH"

# Fix #3: eval_pilot2_standardized.py dataset parsing
[ "$(md5 -r evaluation/benchmarks/multi_swe_bench/scripts/eval_pilot2_standardized.py | cut -d' ' -f1)" = "c71b963ae19398e900681ec2340da445" ] && echo "✓ eval_pilot2_standardized.py" || echo "✗ eval_pilot2_standardized.py MISMATCH"

# Fix #4: run_full_eval_with_s3.sh complete pipeline
[ -f evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh ] && echo "✓ run_full_eval_with_s3.sh" || echo "✗ run_full_eval_with_s3.sh MISSING"

# Fix #5: build_vscode.py for Poetry
[ -f build_vscode.py ] && echo "✓ build_vscode.py" || echo "✗ build_vscode.py MISSING"

# Fix #6: Git repository
git rev-parse HEAD >/dev/null 2>&1 && echo "✓ Git initialized" || echo "✗ NOT a git repo"

# Fix #7: PYTHONPATH (for VeloraHarness runs)
[ -n "$PYTHONPATH" ] && echo "✓ PYTHONPATH set" || echo "⚠ PYTHONPATH not set (needed for VeloraHarness)"

# Fix #8: datasets package
poetry run python -c "import datasets" 2>/dev/null && echo "✓ datasets" || echo "✗ datasets MISSING"
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
