# OpenHands Evaluation Pipeline - Troubleshooting Guide

This document contains all the issues encountered and their fixes while running the `run_full_eval_with_s3.sh` script for trajectory generation and evaluation.

---

## Table of Contents

1. [Issue #1: Poetry Dependencies Not Installed](#issue-1-poetry-dependencies-not-installed)
2. [Issue #2: RUNTIME_CONTAINER_IMAGE="skip" Error](#issue-2-runtime_container_imageskip-error)
3. [Issue #3: ModuleNotFoundError - openhands.agenthub](#issue-3-modulenotfounderror---openhandsagenthub)
4. [Issue #4: TmuxCommandNotFound - Runtime Container Crash](#issue-4-tmuxcommandnotfound---runtime-container-crash)
5. [Issue #5: Broken Docker Base Image (Proxy & APT Sources)](#issue-5-broken-docker-base-image-proxy--apt-sources)
6. [Issue #6: Cached Runtime Images with Bad Base](#issue-6-cached-runtime-images-with-bad-base)
7. [Issue #7: Script Re-tagging Fixed Image](#issue-7-script-re-tagging-fixed-image)
8. [Issue #8: GPT-5.2-codex API Timeout with High Reasoning Effort](#issue-8-gpt-52-codex-api-timeout-with-high-reasoning-effort)
9. [Quick Reference - Commands](#quick-reference---commands)

---

## Issue #1: Poetry Dependencies Not Installed

### Symptoms
```
ModuleNotFoundError: No module named 'pandas'
ModuleNotFoundError: No module named 'datasets'
```

### Root Cause
Poetry dependencies were not installed, especially the evaluation-specific packages.

### Fix
Run poetry install with the evaluation group:

```bash
cd /path/to/VeloraHarness
poetry install --with evaluation
```

### Notes
- You may see an error about missing `build_vscode.py` - this can be ignored as core dependencies will still install.

---

## Issue #2: RUNTIME_CONTAINER_IMAGE="skip" Error

### Symptoms
```
docker: invalid reference format
Error: Unable to find image 'skip:latest' locally
```

### Root Cause
The script had a line `export RUNTIME_CONTAINER_IMAGE="skip"` which was interpreted literally as a Docker image name.

### Fix
Remove or comment out this line from `run_full_eval_with_s3.sh`:

```bash
# REMOVE THIS LINE:
export RUNTIME_CONTAINER_IMAGE="skip"
```

### Location
`evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh` (around line 40)

---

## Issue #3: ModuleNotFoundError - openhands.agenthub

### Symptoms
```
ModuleNotFoundError: No module named 'openhands.agenthub'
ModuleNotFoundError: No module named 'openhands'
```

### Root Cause
The Python path doesn't include the local openhands module directory.

### Fix
Add PYTHONPATH export to the script. Add this line near the top of `run_full_eval_with_s3.sh`:

```bash
export PYTHONPATH="$(pwd):$PYTHONPATH"
```

### Location
Add after the environment variable exports section in `run_full_eval_with_s3.sh`

---

## Issue #4: TmuxCommandNotFound - Runtime Container Crash

### Symptoms
```
Exit Code: 3
openhands.runtime.utils.bash.TmuxCommandNotFound
Container exited unexpectedly
```

### Root Cause
The base Docker image (mswebench/sweb.eval.x86_64.*) doesn't have `tmux` installed, which is required by OpenHands for bash session management.

### Why tmux Couldn't Install
The base image had:
1. Broken proxy settings (`http_proxy=0.0.0.0:8080`)
2. Wrong apt sources (Debian Stretch instead of Ubuntu Jammy)

### Fix
See Issue #5 for the complete fix.

---

## Issue #5: Broken Docker Base Image (Proxy & APT Sources)

### Symptoms
```
E: Failed to fetch http://archive.ubuntu.com/ubuntu/...
W: Failed to fetch... Connection refused
apt-get update fails inside container
```

### Root Cause
The mswebench base Docker images have:
1. Invalid proxy settings: `http_proxy=0.0.0.0:8080`
2. Wrong apt sources: Points to Debian Stretch instead of Ubuntu Jammy

### Fix - Create Fixed Docker Image

```bash
# 1. Get the image name from your dataset
IMAGE_TAG="mswebench/sweb.eval.x86_64.YOUR_INSTANCE_ID:latest"

# 2. Run a container from the broken image
docker run -d --name tmux_fix --entrypoint /bin/bash $IMAGE_TAG -c "sleep 300"

# 3. Fix sources and install tmux inside the container
docker exec tmux_fix bash -c "
  # Fix apt sources to Ubuntu Jammy
  cat > /etc/apt/sources.list << 'EOF'
deb http://archive.ubuntu.com/ubuntu/ jammy main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ jammy-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ jammy-security main restricted universe multiverse
EOF

  # Clear proxy settings
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

  # Update and install tmux
  apt-get update && apt-get install -y tmux
"

# 4. Commit the fixed container as a new image
docker commit tmux_fix ${IMAGE_TAG}-fixed

# 5. Tag the fixed image as the main tag
docker tag ${IMAGE_TAG}-fixed $IMAGE_TAG

# 6. Cleanup
docker stop tmux_fix
docker rm tmux_fix

# 7. Verify tmux is installed
docker run --rm --entrypoint /bin/bash $IMAGE_TAG -c "which tmux"
# Should output: /usr/bin/tmux
```

### Example for Instance 518290527943513
```bash
docker run -d --name tmux_fix --entrypoint /bin/bash mswebench/sweb.eval.x86_64.518290527943513:latest -c "sleep 300"

docker exec tmux_fix bash -c "
  cat > /etc/apt/sources.list << 'EOF'
deb http://archive.ubuntu.com/ubuntu/ jammy main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ jammy-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ jammy-security main restricted universe multiverse
EOF
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
  apt-get update && apt-get install -y tmux
"

docker commit tmux_fix mswebench/sweb.eval.x86_64.518290527943513:latest-fixed
docker tag mswebench/sweb.eval.x86_64.518290527943513:latest-fixed mswebench/sweb.eval.x86_64.518290527943513:latest
docker stop tmux_fix && docker rm tmux_fix
```

---

## Issue #6: Cached Runtime Images with Bad Base

### Symptoms
After fixing the base image, you still get tmux errors because OpenHands is using cached runtime images built from the old broken base.

### Root Cause
OpenHands caches built runtime images with tags like:
```
ghcr.io/openhands/runtime:oh_v0.62.0_xxxxx
```

These were built from the broken base image and don't have tmux.

### Fix - Delete Cached Runtime Images

```bash
# List cached runtime images
docker images | grep "ghcr.io/openhands/runtime"

# Delete all cached runtime images
docker rmi -f $(docker images --format "{{.Repository}}:{{.Tag}}" | grep "ghcr.io/openhands/runtime")
```

### Notes
- After deleting, OpenHands will rebuild the runtime image from your fixed base image
- The rebuild takes a few minutes but only happens once

---

## Issue #7: Script Re-tagging Fixed Image

### Symptoms
After fixing the Docker image, running the script again overwrites your fixed image with the original broken image (from S3).

### Root Cause
The script always re-tags the downloaded S3 image, overwriting your fixed image.

### Fix - Modify Script to Preserve Fixed Images

Add this check to `run_full_eval_with_s3.sh` in the tagging section:

```bash
# Check if TAG1 already exists and has tmux (fixed image)
if docker run --rm --entrypoint /bin/bash "$TAG1" -c "which tmux" >/dev/null 2>&1; then
  echo "✓ Fixed image already exists with tmux - skipping re-tag"
else
  echo "Tagging image..."
  docker tag "$IMAGE_URI" "$TAG1"
  docker tag "$IMAGE_URI" "$TAG2"
  echo "✓ Image tagged successfully"
fi
```

### Location
Replace the existing tagging section in `run_full_eval_with_s3.sh` (around lines 95-100)

---

## Issue #8: GPT-5.2-codex API Timeout with High Reasoning Effort

### Symptoms
```
litellm.Timeout: APITimeoutError - Connection timed out after 600.0 seconds
litellm.Timeout: APITimeoutError - Connection timed out after 1800.0 seconds
```

Timeouts occur randomly even though individual LLM completions complete in 2-5 minutes. The evaluation gets stuck or fails repeatedly despite successful calls intermixed with timeouts.

### Root Cause
This is a **known issue with GPT-5/5.2-codex models when using `reasoning_effort: "high"`**. The problem is NOT the API processing time, but rather **HTTP connection inactivity timeout**.

When the model is "thinking" with high reasoning effort:
1. The OpenAI API doesn't send any data back during the reasoning phase
2. The HTTP connection appears idle to intermediate proxies/load balancers
3. These intermediaries close "idle" connections after ~10-30 minutes
4. LiteLLM sees this as a timeout even though the request was still being processed

**Key insight**: Successful high-reasoning calls complete in 2-5 minutes. The ~30 minute timeout gaps indicate connection drops, not slow processing.

### Fix - Enable Streaming for High Reasoning Models

The fix is to enable **streaming mode** which keeps the HTTP connection alive by sending periodic data chunks.

#### Step 1: Update config.toml

Ensure your `config.toml` has appropriate timeout settings:

```toml
[llm.gpt]
model = "gpt-5.2-codex"
api_key = "sk-proj-your-key-here"
timeout = 1800  # 30 minutes for high reasoning effort
reasoning_effort = "high"
native_tool_calling = false
```

#### Step 2: Modify openhands/llm/llm.py

Add streaming support for GPT-5/codex models with high reasoning. In the `completion_unwrapped` method (around line 324), add:

```python
# Record start time for latency measurement
start_time = time.time()

# Check if we should use streaming to avoid connection timeouts
# GPT-5/5.2-codex with high reasoning effort can take 10+ minutes
# Streaming keeps the connection alive with periodic data chunks
model_lower = self.config.model.lower()
use_streaming = (
    ('gpt-5' in model_lower or 'codex' in model_lower)
    and self.config.reasoning_effort in ('high', 'xhigh')
)

# Suppress httpx deprecation warnings during LiteLLM calls
with warnings.catch_warnings():
    warnings.filterwarnings(
        'ignore', category=DeprecationWarning, module='httpx.*'
    )
    warnings.filterwarnings(
        'ignore',
        message=r'.*content=.*upload.*',
        category=DeprecationWarning,
    )
    if use_streaming:
        # Use streaming to avoid connection timeouts on long-running requests
        # Collect chunks and aggregate into a ModelResponse
        stream_kwargs = {**kwargs, 'stream': True}
        stream_resp = self._completion_unwrapped(*args, **stream_kwargs)
        chunks = []
        for chunk in stream_resp:
            chunks.append(chunk)
        # Use litellm's stream_chunk_builder to aggregate chunks into ModelResponse
        resp: ModelResponse = litellm.stream_chunk_builder(
            chunks, messages=kwargs.get('messages', [])
        )
        if resp is None:
            raise LLMNoResponseError('Streaming response aggregation returned None')
    else:
        resp: ModelResponse = self._completion_unwrapped(*args, **kwargs)
```

### How the Fix Works

1. **Streaming mode** is automatically enabled for GPT-5/codex models with `reasoning_effort` set to "high" or "xhigh"
2. Instead of waiting for one big response, the API sends data in chunks
3. Each chunk keeps the HTTP connection alive
4. `litellm.stream_chunk_builder()` aggregates all chunks back into a standard `ModelResponse`
5. The rest of the code works unchanged since it receives the same response format

### Verification

After applying the fix, monitor the LLM completions log:
```bash
tail -f evaluation/evaluation_outputs/outputs/.../llm_completions/*/completion_*.json
```

You should see:
- Consistent completions every 2-5 minutes
- No more 30-minute timeout gaps
- Successful trajectory generation

### Results

Before fix:
- ~95% timeout rate with GPT-5.2-codex + high reasoning
- Random failures during evaluation

After fix:
- 0% timeout rate
- 21+ consecutive completions without any timeouts
- Full evaluation pipeline completes successfully

### Notes

- This fix only affects GPT-5/codex models with high/xhigh reasoning effort
- Other models continue to use non-streaming mode
- The streaming aggregation is transparent to the rest of the codebase
- If you cannot modify the code, consider using `reasoning_effort: "medium"` as a workaround (though this may affect solution quality)

---

## Quick Reference - Commands

### Check if Docker image has tmux
```bash
docker run --rm --entrypoint /bin/bash IMAGE_NAME:TAG -c "which tmux"
```

### Check Docker image's apt sources
```bash
docker run --rm --entrypoint /bin/bash IMAGE_NAME:TAG -c "cat /etc/apt/sources.list"
```

### Check Docker image's proxy settings
```bash
docker run --rm --entrypoint /bin/bash IMAGE_NAME:TAG -c "env | grep -i proxy"
```

### List all mswebench images
```bash
docker images | grep mswebench
```

### List all OpenHands runtime images
```bash
docker images | grep "ghcr.io/openhands/runtime"
```

### Check running containers
```bash
docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
```

### Install poetry dependencies
```bash
poetry install --with evaluation
```

### Run evaluation with proper PYTHONPATH
```bash
export PYTHONPATH="$(pwd):$PYTHONPATH"
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh
```

---

## Complete Script Modifications Summary

### File: `run_full_eval_with_s3.sh`

1. **Remove** (around line 40):
   ```bash
   export RUNTIME_CONTAINER_IMAGE="skip"
   ```

2. **Add** (after environment exports):
   ```bash
   export PYTHONPATH="$(pwd):$PYTHONPATH"
   ```

3. **Replace tagging section** (around line 95-100):
   ```bash
   # Check if TAG1 already exists and has tmux (fixed image)
   if docker run --rm --entrypoint /bin/bash "$TAG1" -c "which tmux" >/dev/null 2>&1; then
     echo "✓ Fixed image already exists with tmux - skipping re-tag"
   else
     echo "Tagging image..."
     docker tag "$IMAGE_URI" "$TAG1"
     docker tag "$IMAGE_URI" "$TAG2"
     echo "✓ Image tagged successfully"
   fi
   ```

---

## Pre-flight Checklist

Before running the evaluation script:

- [ ] Poetry dependencies installed: `poetry install --with evaluation`
- [ ] Docker is running: `docker ps`
- [ ] AWS CLI configured: `aws s3 ls s3://your-bucket/ --region your-region`
- [ ] Script modifications applied (see above)
- [ ] Base Docker image fixed with tmux (if using S3 images)
- [ ] Cached runtime images deleted (if previously built from broken base)
- [ ] LLM API keys configured in `config.toml`
- [ ] Streaming fix applied to `openhands/llm/llm.py` (if using GPT-5.2-codex with high reasoning)

---

## Expected Successful Output

When everything works correctly, you should see:

```
============================================
VELORA FULL EVALUATION WITH S3 DOWNLOAD
============================================
...
✓ Fixed image already exists with tmux - skipping re-tag
...
============================================
PHASE 1: TRAJECTORY GENERATION
============================================
...
Instances processed: 100%|██████████| 1/1 [17:20<00:00, 1040.55s/it]
...
============================================
PHASE 2: DETAILED PATCH EVALUATION
============================================
...
EVALUATION RESULTS
Instance ID: XXXXX
RESOLVED: YES/NO
Tests Passed: XX
Tests Failed: XX
```

---

## Document Info

- **Created**: 2026-01-27
- **Last Updated**: 2026-01-30
- **Repository**: Velora_SWE_Harness/VeloraHarness
- **Script**: `evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh`
- **Key Files Modified**:
  - `openhands/llm/llm.py` - Streaming fix for GPT-5.2-codex timeout issues
  - `config.toml` - LLM configuration with timeout settings
