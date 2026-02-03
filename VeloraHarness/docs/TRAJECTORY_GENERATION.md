# Trajectory Generation Guide for VeloraHarness

This document describes the changes required and the command to generate trajectories using the Multi-SWE-Bench evaluation framework.

## Prerequisites

1. **Docker** must be installed and running
2. **Poetry** must be installed (version 2.1.2+)
3. **Python 3.12** is required
4. **OpenAI API key** configured in `config.toml`

## Required Code Changes

The following changes were made to enable trajectory generation:

### 1. Added `action_execution_server.py`

**File:** `openhands/runtime/action_execution_server.py`

This file was missing from the codebase but is required by the Docker runtime. It implements the FastAPI server that runs inside the Docker container and executes actions from the agent.

**Key features added:**
- ActionExecutor class for handling agent actions
- REST API endpoints for action execution
- Support for `--no-enable-browser` flag to disable browser initialization
- `/update_mcp_server` endpoint (no-op for evaluation)

### 2. Modified `config.toml`

**Change:** Commented out the `runtime_container_image` setting to force rebuilding of runtime images with the new code.

```toml
# Runtime container image to use (if not provided, will be built from base_container_image)
# Commented out to force rebuild with action_execution_server.py
#runtime_container_image = "ghcr.io/openhands/runtime:oh_v0.62.0_3rpe8pjvgv5kt50s"
```

### 3. LLM Configuration

Ensure your `config.toml` has the correct LLM settings:

```toml
[llm.gpt]
model = "gpt-4o"
api_key = "YOUR_OPENAI_API_KEY"
temperature = 0.2
max_input_tokens = 128000
max_output_tokens = 16384  # Note: gpt-4o supports max 16384 output tokens
```

**Important:** The `max_output_tokens` should be set to `16384` (not `64000`) for gpt-4o model.

## Command to Generate Trajectories

### Basic Command

```bash
cd ~/Velora_SWE_Harness-2/VeloraHarness

LANGUAGE=python poetry run python -m evaluation.benchmarks.multi_swe_bench.run_infer \
    --agent-cls CodeActAgent \
    --llm-config llm.gpt \
    --max-iterations 50 \
    --eval-n-limit 1 \
    --dataset data/sample_task.jsonl \
    --split train
```

### Full Command with All Parameters

```bash
cd ~/Velora_SWE_Harness-2/VeloraHarness

LANGUAGE=python \
USE_HINT_TEXT=false \
USE_INSTANCE_IMAGE=true \
RUN_WITH_BROWSING=false \
EVAL_DOCKER_IMAGE_PREFIX=mswebench \
poetry run python -m evaluation.benchmarks.multi_swe_bench.run_infer \
    --agent-cls CodeActAgent \
    --llm-config llm.gpt \
    --max-iterations 50 \
    --eval-n-limit 1 \
    --eval-num-workers 1 \
    --dataset data/sample_task.jsonl \
    --split train \
    --eval-output-dir evaluation/evaluation_outputs
```

## Command Line Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `--agent-cls` | str | CodeActAgent | Agent class to use (CodeActAgent, DummyAgent, etc.) |
| `--llm-config` | str | (required) | LLM config section from config.toml (e.g., `llm.gpt`) |
| `--max-iterations` | int | 500 | Maximum number of agent iterations per task |
| `--eval-n-limit` | int | (all) | Maximum number of tasks to process |
| `--eval-num-workers` | int | 1 | Number of parallel workers for evaluation |
| `--dataset` | str | (required) | Path to JSONL dataset file |
| `--split` | str | test | Dataset split to use (`train` for local JSONL files) |
| `--eval-output-dir` | str | evaluation/evaluation_outputs | Output directory for results |
| `--eval-note` | str | empty | Run identifier suffix for organizing outputs |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LANGUAGE` | java | Programming language of tasks (`python`, `java`, `go`, `c`, `cpp`, `javascript`, `typescript`, `rust`) |
| `USE_HINT_TEXT` | false | Whether to include hints in the agent prompt |
| `USE_INSTANCE_IMAGE` | true | Use instance-specific Docker images |
| `RUN_WITH_BROWSING` | false | Enable web browsing tools for the agent |
| `EVAL_DOCKER_IMAGE_PREFIX` | mswebench | Docker image prefix for instance images |
| `RUNTIME_CONTAINER_IMAGE` | (auto) | Pre-built runtime image URI (skips build if set) |
| `SKIP_IDS` | empty | Comma-separated instance IDs to skip |

## Output Structure

After running inference, outputs are created in:

```
evaluation/evaluation_outputs/outputs/
└── data__sample_task.jsonl-train/
    └── CodeActAgent/
        └── gpt-4o_maxiter_50/
            ├── output.jsonl          # Main trajectory output
            ├── metadata.json         # Run configuration
            ├── llm_completions/      # LLM API call logs
            │   └── <instance_id>/
            └── infer_logs/           # Per-instance logs
                └── instance_<instance_id>.log
```

### Output File Format (`output.jsonl`)

Each line in `output.jsonl` is a JSON object containing:

```json
{
  "instance_id": "tobymao__sqlglot-e604fe6d8258",
  "instruction": "...",
  "test_result": {
    "git_patch": "diff --git a/...",
    "...": "..."
  },
  "history": [...],
  "metrics": {...},
  "error": null
}
```

## Loading Docker Images from S3

If you have pre-pulled Docker images in the `s3_image_pull` folder:

```bash
# Load the Docker image
docker load -i s3_image_pull/tobymao_sqlglot-e604fe6d8258c73b511159a953bb130c65b608cc.tar

# Verify it's loaded
docker images | grep sqlglot
```

## Troubleshooting

### 1. "Container has exited" Error

**Cause:** The runtime container is failing to start the action execution server.

**Solution:** Ensure `action_execution_server.py` exists in `openhands/runtime/` and contains all required endpoints.

### 2. "max_tokens is too large" Error

**Cause:** The `max_output_tokens` in config.toml exceeds the model's limit.

**Solution:** Set `max_output_tokens = 16384` for gpt-4o model.

### 3. "Split 'test' not found" Error

**Cause:** Local JSONL files default to the 'train' split.

**Solution:** Use `--split train` when running with local JSONL datasets.

### 4. Browser Initialization Errors

**Cause:** Playwright browsers not installed in the container.

**Solution:** This is non-fatal when `RUN_WITH_BROWSING=false`. The agent will work without browser capabilities.

### 5. "404 Not Found for /update_mcp_server"

**Cause:** Missing MCP server endpoint in action_execution_server.py.

**Solution:** Add a no-op endpoint for `/update_mcp_server` in the server.

## Example: Running Full Evaluation Pipeline

```bash
# Run the full evaluation pipeline (inference + evaluation)
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval.sh \
    llm.gpt \
    data/sample_task.jsonl \
    1 \
    50 \
    1 \
    CodeActAgent
```

This script:
1. **Phase 1:** Runs `run_infer.py` to generate trajectories
2. **Phase 2:** Runs evaluation to test patches
3. Saves results with metadata and logs

## Monitoring Progress

While the evaluation is running, you can monitor progress:

```bash
# Watch the inference log
tail -f evaluation/evaluation_outputs/outputs/data__sample_task.jsonl-train/CodeActAgent/gpt-4o_maxiter_50/infer_logs/instance_*.log

# Check Docker container status
docker ps -a --filter "name=openhands-runtime"

# View container logs
docker logs <container_name>
```

---

## Technical Analysis: Why `action_execution_server.py` Was Required

### The Core Problem

The VeloraHarness codebase is based on **OpenHands v0.62.0**, but the `action_execution_server.py` file was **removed or refactored out** in this version. However, the code architecture still expects this module to exist:

```python
# From openhands/runtime/utils/command.py:15
DEFAULT_MAIN_MODULE = 'openhands.runtime.action_execution_server'
```

The Docker runtime starts a container and runs:
```bash
python -m openhands.runtime.action_execution_server <port> --working-dir /workspace ...
```

### Why the Pre-built Image Doesn't Work

The pre-built image `ghcr.io/openhands/runtime:oh_v0.62.0_3rpe8pjvgv5kt50s` was built from this same codebase (v0.62.0) which is **missing** `action_execution_server.py`. That's why the container exits immediately with:

```
ModuleNotFoundError: No module named 'openhands.runtime.action_execution_server'
```

### Verification

```bash
# Check if pre-built v0.62.0 image has action_execution_server.py
docker run --rm --entrypoint bash ghcr.io/openhands/runtime:oh_v0.62.0_3rpe8pjvgv5kt50s \
    -c "find /openhands/code -name 'action_execution_server*'"
# Result: Empty (file does not exist)

# Check if older v0.33 image has it
docker run --rm --entrypoint bash ghcr.io/all-hands-ai/runtime:0.33-nikolaik \
    -c "ls -la /openhands/code/openhands/runtime/action_execution_server.py"
# Result: File exists (34113 bytes)
```

### Alternative Solutions Considered

| Approach | Viable? | Notes |
|----------|---------|-------|
| **Add `action_execution_server.py`** | ✅ Yes | What we did - most direct fix |
| **Use older runtime image (v0.33)** | ⚠️ Maybe | Version incompatibility risk between v0.33 runtime and v0.62.0 client |
| **Use original OpenHands repo** | ✅ Yes | But defeats the purpose of using VeloraHarness |
| **Modify `command.py` to use different module** | ❌ No | No alternative module provides the required FastAPI server functionality |

### Why We Chose to Add the File

1. **Direct Compatibility**: Adding the file ensures the runtime works with the existing v0.62.0 codebase
2. **Minimal Changes**: Only one file needed to be added (plus minor modifications for `--no-enable-browser` and `/update_mcp_server`)
3. **No Version Conflicts**: Avoids potential API incompatibilities between different OpenHands versions

### Additional Modifications to `action_execution_server.py`

The file extracted from v0.33 required these updates to work with v0.62.0:

1. **`--no-enable-browser` flag**: Added to support disabling browser initialization (required by the command generator in v0.62.0)
2. **`/update_mcp_server` endpoint**: Added as a no-op endpoint (called by the v0.62.0 client but not present in v0.33 server)
3. **`enable_browser` parameter in `ActionExecutor.__init__`**: Added to conditionally skip browser initialization

### Conclusion

**The file was strictly required because:**
1. The codebase architecture (`command.py`) depends on `openhands.runtime.action_execution_server` module
2. The pre-built runtime images for v0.62.0 also lack this file
3. Using an older runtime version (v0.33) would introduce version incompatibility risks

The only truly alternative approach would be to use a completely different OpenHands version/repository, which would require significant changes to the evaluation scripts.
