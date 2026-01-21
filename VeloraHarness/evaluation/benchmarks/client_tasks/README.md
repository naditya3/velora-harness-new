# Client Tasks Evaluation (Repomate Harness)

This module provides evaluation scripts for client tasks (Repomate) that differ from standard SWE-bench:

| Feature | SWE-bench | Client Tasks |
|---------|-----------|--------------|
| Working directory | `/testbed` | `/app/repo` |
| Environment | `conda activate testbed` | `source /saved/ENV` |
| Test patches | Single patch | JSON array (1-77 patches) |
| Parser | Per-repo hardcoded | Per-task from CSV `test_output_parser` |
| Test command | Per-repo hardcoded | Per-task from CSV `test_command` |

## Quick Start

### 1. Full Pipeline (Trajectory + Evaluation)

```bash
cd VeloraHarness/evaluation/benchmarks/client_tasks/scripts

./rollout_client_task.sh <dataset_jsonl> <llm_config> [max_iterations] [output_dir]

# Example:
./rollout_client_task.sh ~/datasets/task1.jsonl llm.gpt 50 ~/output
```

### 2. Evaluation Only (After Trajectory Generation)

```bash
python eval_client_harness.py \
    --trajectory-output /path/to/output.jsonl \
    --dataset /path/to/dataset.jsonl \
    --output-dir ~/output/eval_output \
    --timeout 900
```

## Output Format

Output matches OpenHands format for compatibility:

```
eval_output/
├── summary.json              # Overall statistics
├── eval_results.jsonl        # Detailed results per instance
└── <instance_id>/
    ├── report.json           # OpenHands-format F2P/P2P results
    └── test_output.txt       # Raw test output
```

### report.json Format

```json
{
    "<instance_id>": {
        "patch_is_None": false,
        "patch_exists": true,
        "patch_successfully_applied": true,
        "resolved": false,
        "tests_status": {
            "FAIL_TO_PASS": {
                "success": ["test_a", "test_b"],
                "failure": ["test_c"]
            },
            "PASS_TO_PASS": {
                "success": ["test_d", "test_e"],
                "failure": []
            },
            "FAIL_TO_FAIL": {"success": [], "failure": []},
            "PASS_TO_FAIL": {"success": [], "failure": []}
        }
    }
}
```

## Dataset Format

The dataset JSONL should have these fields (from client CSV):

| Field | Description | Example |
|-------|-------------|---------|
| `instance_id` | Unique task ID | `1319603449576684` |
| `test_command` | Test command to run | `pytest --no-header -rA` |
| `test_output_parser` | Parser to use | `python/parse_log_pytest_v3` |
| `test_patch` | JSON array of patches | `["diff --git...", "diff..."]` |
| `fail_to_pass_tests` | Tests that should pass after fix | `["test_a", "test_b"]` |
| `pass_to_pass_tests` | Tests that should remain passing | `["test_c"]` |
| `base_commit` | Git commit to reset to | `abc123...` |
| `image_storage_uri` | Docker image | `registry/repo:tag` |

## Supported Parsers

- `python/parse_log_pytest` - Basic pytest
- `python/parse_log_pytest_v2` - pytest with -rA
- `python/parse_log_pytest_v3` - Repomate pytest (most common)
- `python/parse_log_unittest` - Python unittest
- `python/parse_log_tox` - tox output

## Key Differences from OpenHands Evaluation

1. **No output truncation** - Captures full test output (OpenHands truncates at 30,000 chars)
2. **Per-task configuration** - Uses test_command and parser from dataset, not hardcoded
3. **Client harness alignment** - Uses `/app/repo` and `source /saved/ENV`
4. **JSON array patches** - Handles test_patch as array of 1-77 patches

## Troubleshooting

### Patch Application Fails
- Check if patch ends with newline (required by git apply)
- For complex patches, base64 encoding is used automatically

### Test Not Found
- Verify test names in F2P/P2P lists match pytest output format
- Check `test_output_parser` is correct for the test framework

### Docker Image Issues
- Ensure image is tagged correctly: `mswebench/<repo>:pr-<instance_id>`
- Working directory must be `/app/repo`

