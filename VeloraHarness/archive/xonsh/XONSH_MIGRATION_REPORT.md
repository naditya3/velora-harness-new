# VeloraHarness Shell Script to Xonsh Migration Report

## Executive Summary

**Date:** 2026-01-30
**Total Shell Scripts Found:** 25
**Critical Scripts Converted:** 2 (with 2 more recommended)
**Status:** Initial conversion complete for evaluation pipeline

## All Shell Scripts Found

### Multi SWE-Bench Evaluation Scripts (Critical)
1. `/evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval.sh`
2. `/evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_fixed.sh`
3. `/evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_local_docker.sh`
4. **`/evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh`** ✓ CONVERTED
5. **`/evaluation/benchmarks/multi_swe_bench/scripts/run_velora_infer.sh`** ✓ CONVERTED
6. `/evaluation/benchmarks/multi_swe_bench/scripts/setup/instance_swe_entry.sh`
7. `/evaluation/benchmarks/multi_swe_bench/scripts/setup/swe_entry.sh`

### SWE-Bench Evaluation Scripts (High Priority)
8. `/evaluation/benchmarks/swe_bench/scripts/docker/pull_all_eval_docker.sh`
9. `/evaluation/benchmarks/swe_bench/scripts/docker/push_eval_docker.sh`
10. `/evaluation/benchmarks/swe_bench/scripts/eval/convert_oh_folder_to_swebench_submission.sh`
11. `/evaluation/benchmarks/swe_bench/scripts/eval_infer.sh`
12. `/evaluation/benchmarks/swe_bench/scripts/eval_localization.sh`
13. `/evaluation/benchmarks/swe_bench/scripts/rollout_swegym.sh`
14. **`/evaluation/benchmarks/swe_bench/scripts/run_infer.sh`** (Recommend converting)
15. `/evaluation/benchmarks/swe_bench/scripts/run_infer_interact.sh`
16. `/evaluation/benchmarks/swe_bench/scripts/run_localize.sh`
17. `/evaluation/benchmarks/swe_bench/scripts/setup/instance_swe_entry.sh`
18. `/evaluation/benchmarks/swe_bench/scripts/setup/instance_swe_entry_live.sh`
19. `/evaluation/benchmarks/swe_bench/scripts/setup/instance_swe_entry_rebench.sh`
20. `/evaluation/benchmarks/swe_bench/scripts/setup/prepare_swe_utils.sh`
21. `/evaluation/benchmarks/swe_bench/scripts/setup/swe_entry.sh`

### Client Tasks Scripts (Medium Priority)
22. `/evaluation/benchmarks/client_tasks/scripts/rollout_client_task.sh`
23. `/evaluation/benchmarks/client_tasks/scripts/run_client_eval.sh`
24. `/evaluation/benchmarks/client_tasks/scripts/run_client_task.sh`

### Utility Scripts (Low Priority)
25. **`/scripts/run_tasks_v2.sh`** (Recommend converting - orchestration)
26. `/scripts/verify_aws_consistency.sh`

## Converted Scripts

### 1. run_full_eval_with_s3.xsh ✓
**Location:** `/evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.xsh`

**Purpose:** Complete evaluation pipeline with S3 Docker image download

**Key Features:**
- Downloads Docker images from S3
- Tags images for OpenHands
- Runs trajectory generation
- Performs patch evaluation
- Creates OpenHands-format reports

**Xonsh Improvements:**
- Native Python integration for JSON parsing
- Better error handling with Python exceptions
- Cleaner environment variable management
- Path handling with pathlib
- No subprocess for simple operations

**Usage:**
```bash
./run_full_eval_with_s3.xsh llm.gpt data/task.jsonl 1 30 1
```

### 2. run_velora_infer.xsh ✓
**Location:** `/evaluation/benchmarks/multi_swe_bench/scripts/run_velora_infer.xsh`

**Purpose:** Trajectory generation for Velora tasks

**Key Features:**
- Configurable model selection
- Iteration control
- Worker parallelization
- Environment setup

**Xonsh Improvements:**
- Simplified argument parsing
- Direct Python logic
- Cleaner control flow
- Better type handling

**Usage:**
```bash
./run_velora_infer.xsh llm.gpt ~/datasets/task.jsonl 1 200 1
```

## Key Xonsh Syntax Features Used

### Environment Variables
```python
# Bash
export DOCKER_BUILDKIT=0

# Xonsh
$DOCKER_BUILDKIT = "0"
```

### Command Execution
```python
# Bash
docker images --format "{{.Repository}}:{{.Tag}}"

# Xonsh
docker images --format "{{.Repository}}:{{.Tag}}"
# or with variable interpolation
docker tag @(image_uri) @(tag1)
```

### Conditionals
```python
# Bash
if [ -z "$VAR" ]; then
    echo "empty"
fi

# Xonsh
if not var:
    print("empty")
```

### Loops
```python
# Bash
for i in $(seq 1 $N_RUNS); do
    echo $i
done

# Xonsh
for i in range(1, n_runs + 1):
    print(i)
```

### Command Output Capture
```python
# Bash
OUTPUT=$(command)

# Xonsh
output = $(command).strip()
```

### File Operations
```python
# Bash
if [ -f "$FILE" ]; then

# Xonsh
from pathlib import Path
if Path(file).exists():
```

## Migration Benefits

### Advantages of Xonsh
1. **Python Integration:** Direct access to Python libraries (json, pathlib, subprocess)
2. **Better Error Handling:** Python exceptions instead of exit codes
3. **Type Safety:** Python typing for better code clarity
4. **Data Structures:** Native lists, dictionaries, sets
5. **String Manipulation:** Python string methods instead of sed/awk
6. **JSON Handling:** Native json module vs jq
7. **Readability:** More intuitive Python syntax
8. **Debugging:** Python debugger support
9. **Testing:** Python unittest/pytest integration
10. **Cross-platform:** Better Windows support

### Disadvantages/Considerations
1. **Learning Curve:** Team needs to know xonsh syntax
2. **Tooling:** May need xonsh installed on all machines
3. **Legacy:** Existing bash scripts need migration
4. **CI/CD:** Build pipelines may need updates
5. **Documentation:** Less Stack Overflow support than bash

## Recommended Next Steps

### Phase 1: Critical Evaluation Scripts (COMPLETED)
- [x] `run_full_eval_with_s3.sh` → `.xsh`
- [x] `run_velora_infer.sh` → `.xsh`

### Phase 2: High-Value Orchestration (RECOMMENDED)
- [ ] `scripts/run_tasks_v2.sh` → `.xsh` (orchestration logic)
- [ ] `evaluation/benchmarks/swe_bench/scripts/run_infer.sh` → `.xsh`
- [ ] `run_full_eval_fixed.sh` → `.xsh`
- [ ] `run_full_eval_local_docker.sh` → `.xsh`

### Phase 3: Setup Scripts (AS NEEDED)
- [ ] `setup/swe_entry.sh` → `.xsh`
- [ ] `setup/instance_swe_entry.sh` → `.xsh`
- [ ] Docker management scripts

### Phase 4: Utility Scripts (LOW PRIORITY)
- [ ] Client task scripts
- [ ] AWS verification scripts
- [ ] Docker push/pull scripts

## Testing Strategy

### 1. Unit Testing
Create test fixtures for each xonsh script:
```python
# test_run_velora_infer.py
import pytest
from pathlib import Path

def test_parse_args():
    # Test argument parsing
    pass

def test_environment_setup():
    # Test environment variables
    pass
```

### 2. Integration Testing
Test full evaluation pipeline:
```bash
# Test with small dataset
./run_full_eval_with_s3.xsh llm.gpt test_data.jsonl 1 5 1

# Verify outputs
ls evaluation/evaluation_outputs/outputs/
```

### 3. Comparison Testing
Run both bash and xonsh versions side-by-side:
```bash
# Bash version
./run_velora_infer.sh llm.gpt data.jsonl 1 200 1

# Xonsh version
./run_velora_infer.xsh llm.gpt data.jsonl 1 200 1

# Compare outputs
diff -r output_bash/ output_xonsh/
```

## Installation Requirements

### Installing Xonsh
```bash
# Via pip
pip install xonsh

# Via conda
conda install -c conda-forge xonsh

# Verify installation
xonsh --version
```

### Making Scripts Executable
```bash
chmod +x *.xsh
```

### Setting Default Shell (Optional)
```bash
# Add to .bashrc or .zshrc
alias xsh='xonsh'
```

## Migration Checklist

When converting a bash script to xonsh:

- [ ] Replace `#!/bin/bash` with `#!/usr/bin/env xonsh`
- [ ] Convert `export VAR=value` to `$VAR = "value"`
- [ ] Replace `$VAR` with `@(var)` for command interpolation
- [ ] Convert `if [ ... ]` to Python `if` statements
- [ ] Replace `for ... in ...; do` with Python `for` loops
- [ ] Use `Path()` instead of file test operators
- [ ] Replace `jq` with Python `json` module
- [ ] Convert `grep/sed/awk` to Python string methods
- [ ] Use `$(command).strip()` for command output
- [ ] Replace `set -e` with proper error handling
- [ ] Test thoroughly with real data

## Performance Considerations

### Bash Advantages
- Lower startup time for simple scripts
- Native process spawning
- Shell built-ins are fast

### Xonsh Advantages
- Better for complex logic
- No subprocess overhead for Python code
- Efficient data processing with Python

### Recommendation
- Use xonsh for complex orchestration scripts (run_tasks_v2.sh)
- Use bash for simple wrapper scripts
- Use xonsh for JSON/data processing heavy scripts

## Conclusion

The conversion of the two critical evaluation scripts to xonsh demonstrates the feasibility and benefits of migration. The xonsh versions are:

1. **More Readable:** Python syntax is clearer than bash
2. **More Maintainable:** Better error handling and structure
3. **More Testable:** Python testing frameworks available
4. **More Powerful:** Native Python libraries for data processing

### Immediate Action Items
1. Test the converted scripts with real Velora tasks
2. Create backup copies of original bash scripts
3. Update documentation to reference .xsh scripts
4. Train team on xonsh syntax and best practices
5. Consider converting run_tasks_v2.sh next (highest complexity benefit)

### Long-term Strategy
- Gradual migration as scripts need updates
- Maintain bash versions during transition period
- Create xonsh style guide for consistency
- Build shared xonsh library for common functions
