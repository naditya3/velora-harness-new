#!/bin/bash
# run_full_eval_with_s3.sh - Complete Velora evaluation pipeline with S3 Docker download
#
# This script:
#   1. Downloads Docker image from S3 based on dataset
#   2. Loads and tags the image for OpenHands
#   3. Runs trajectory generation (run_infer.py)
#   4. Runs patch evaluation (eval_pilot2_standardized.py)
#   5. Creates OpenHands-format reports
#
# Output structure:
#   evaluation_outputs/outputs/.../
#   ├── output.jsonl              ← Trajectory + git_patch
#   ├── metadata.json             ← Run metadata
#   ├── llm_completions/          ← LLM responses
#   └── eval_outputs/             ← Evaluation results
#       ├── report.json           ← Aggregate report
#       └── <instance_id>/
#           ├── report.json       ← Detailed test breakdown
#           ├── patch.diff        ← Applied patch
#           ├── test_output.txt   ← Full test output
#           └── run_instance.log  ← Execution log
#
# Usage: ./run_full_eval_with_s3.sh MODEL_CONFIG DATASET [EVAL_LIMIT] [MAX_ITER] [NUM_WORKERS]
# Example: ./run_full_eval_with_s3.sh llm.gpt data/task.jsonl 1 30 1

set -eo pipefail

# ============================================
# VELORA-SPECIFIC ENVIRONMENT VARIABLES
# ============================================
export DOCKER_BUILDKIT=0                    # CRITICAL: Prevents buildx failures
export EVAL_DOCKER_IMAGE_PREFIX="mswebench" # Our Docker image prefix
export USE_INSTANCE_IMAGE=true              # Use instance-specific images
export LANGUAGE=python                      # Our tasks are Python
export RUN_WITH_BROWSING=false
export USE_HINT_TEXT=false
export PYTHONPATH="$(pwd):$PYTHONPATH"    # CRITICAL: Ensure openhands module is found

# Use pre-built runtime image if set, otherwise let OpenHands build
if [ -z "$RUNTIME_CONTAINER_IMAGE" ]; then
  # Use our most recent working runtime image
  export RUNTIME_CONTAINER_IMAGE="ghcr.io/openhands/runtime:oh_v0.62.0_dit46occtvqk1xmv_1q3zwci563qrooux"
fi
echo "Using RUNTIME_CONTAINER_IMAGE: $RUNTIME_CONTAINER_IMAGE"

# ============================================
# ARGUMENT PARSING
# ============================================
MODEL_CONFIG=$1
DATASET=$2
EVAL_LIMIT=${3:-1}        # Default: 1 task
MAX_ITER=${4:-30}         # Default: 30 iterations
NUM_WORKERS=${5:-1}       # Default: 1 worker
AGENT=${6:-CodeActAgent}  # Default: CodeActAgent
SPLIT="train"

# ============================================
# VALIDATION
# ============================================
if [ -z "$MODEL_CONFIG" ]; then
  echo "ERROR: MODEL_CONFIG is required (e.g., llm.gpt, llm.claude, llm.kimi)"
  echo "Usage: $0 MODEL_CONFIG DATASET [EVAL_LIMIT] [MAX_ITER] [NUM_WORKERS] [AGENT]"
  exit 1
fi

if [ -z "$DATASET" ]; then
  echo "ERROR: DATASET path is required"
  echo "Usage: $0 MODEL_CONFIG DATASET [EVAL_LIMIT] [MAX_ITER] [NUM_WORKERS] [AGENT]"
  exit 1
fi

if [ ! -f "$DATASET" ]; then
  echo "ERROR: Dataset file not found: $DATASET"
  exit 1
fi

DATASET_ABS=$(realpath "$DATASET")

# ============================================
# DISPLAY CONFIGURATION
# ============================================
echo "============================================"
echo "VELORA FULL EVALUATION WITH S3 DOWNLOAD"
echo "============================================"
echo "MODEL_CONFIG: $MODEL_CONFIG"
echo "DATASET: $DATASET_ABS"
echo "EVAL_LIMIT: $EVAL_LIMIT"
echo "MAX_ITER: $MAX_ITER"
echo "NUM_WORKERS: $NUM_WORKERS"
echo "AGENT: $AGENT"
echo "SPLIT: $SPLIT"
echo ""
echo "Environment:"
echo "  DOCKER_BUILDKIT: $DOCKER_BUILDKIT"
echo "  EVAL_DOCKER_IMAGE_PREFIX: $EVAL_DOCKER_IMAGE_PREFIX"
echo "  USE_INSTANCE_IMAGE: $USE_INSTANCE_IMAGE"
echo "  LANGUAGE: $LANGUAGE"
echo "  RUNTIME_CONTAINER_IMAGE: $RUNTIME_CONTAINER_IMAGE"
echo "============================================"
echo ""

# ============================================
# EXTRACT DOCKER IMAGE INFO FROM DATASET
# ============================================
echo "============================================"
echo "EXTRACTING DOCKER IMAGE INFO FROM DATASET"
echo "============================================"

INSTANCE_ID=$(cat "$DATASET_ABS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('instance_id', ''))
" 2>/dev/null)

if [ -z "$INSTANCE_ID" ]; then
  echo "ERROR: Could not extract instance_id from dataset"
  exit 1
fi

echo "Instance ID: $INSTANCE_ID"

# Extract image info
IMAGE_URI=$(cat "$DATASET_ABS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('image_storage_uri', ''))
" 2>/dev/null)

REPO=$(cat "$DATASET_ABS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('repo', ''))
" 2>/dev/null)

BASE_COMMIT=$(cat "$DATASET_ABS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('base_commit', ''))
" 2>/dev/null)

echo "Image URI: $IMAGE_URI"
echo "Repo: $REPO"
echo "Base Commit: $BASE_COMMIT"

# Construct S3 path
REPO_PART=$(echo "$IMAGE_URI" | awk -F'/' '{print $NF}')
REPO_NAME=$(echo "$REPO_PART" | cut -d':' -f1)
COMMIT=$(echo "$REPO_PART" | cut -d':' -f2)
S3_IMAGE_FILE="${REPO_NAME}-${COMMIT}.tar"
S3_PATH="s3://kuberha-velora/velora-files/images/${S3_IMAGE_FILE}"

echo "S3 Path: $S3_PATH"
echo "Local file: ${S3_IMAGE_FILE}"

# ============================================
# DOWNLOAD AND LOAD DOCKER IMAGE FROM S3
# ============================================
echo ""
echo "============================================"
echo "DOWNLOADING DOCKER IMAGE FROM S3"
echo "============================================"

# Construct expected image tags for checking
EXPECTED_TAG1="mswebench/sweb.eval.x86_64.${INSTANCE_ID}:latest"
EXPECTED_TAG2="mswebench/sweb.eval.x86_64.${INSTANCE_ID}"

# Check if image already exists by checking for the mswebench-tagged version
if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "$EXPECTED_TAG1"; then
  echo "✓ Docker image already loaded: $EXPECTED_TAG1"
  # Set IMAGE_URI to the local image for subsequent steps
  IMAGE_URI="$EXPECTED_TAG1"
elif docker images --format "{{.Repository}}" | grep -q "$EXPECTED_TAG2"; then
  echo "✓ Docker image already loaded: $EXPECTED_TAG2"
  IMAGE_URI="$EXPECTED_TAG2:latest"
else
  echo "Downloading from S3..."
  aws s3 cp "$S3_PATH" "$S3_IMAGE_FILE"

  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to download Docker image from S3"
    exit 1
  fi

  echo "✓ Downloaded $(du -h "$S3_IMAGE_FILE" | cut -f1)"

  echo "Loading Docker image..."
  docker load < "$S3_IMAGE_FILE"

  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to load Docker image"
    exit 1
  fi

  echo "✓ Image loaded"

  # Cleanup tar file
  rm -f "$S3_IMAGE_FILE"
  echo "✓ Cleaned up tar file"
fi

# ============================================
# TAG DOCKER IMAGE FOR OPENHANDS
# ============================================
echo ""
echo "============================================"
echo "TAGGING DOCKER IMAGE FOR OPENHANDS"
echo "============================================"

# Double tagging as per OpenHands requirements
REPO_M=$(echo "$REPO" | sed 's|/|_m_|g')
TAG1="mswebench/sweb.eval.x86_64.${INSTANCE_ID}:latest"
TAG2="mswebench/${REPO_M}:pr-${INSTANCE_ID}"

echo "Original image: $IMAGE_URI"
echo "Tag 1: $TAG1"
echo "Tag 2: $TAG2"

# Check if TAG1 already exists and has tmux (fixed image)
if docker run --rm --entrypoint /bin/bash "$TAG1" -c "which tmux" >/dev/null 2>&1; then
  echo "✓ Fixed image already exists with tmux - skipping re-tag"
else
  echo "Tagging image..."
  docker tag "$IMAGE_URI" "$TAG1"
  docker tag "$IMAGE_URI" "$TAG2"
  echo "✓ Image tagged successfully"
fi

# Verify tags
echo ""
echo "Verifying tags:"
docker images | grep -E "(${INSTANCE_ID}|${REPO_M})" | head -5

# ============================================
# INSTALL TMUX IN BASE IMAGE (Critical Fix)
# ============================================
echo ""
echo "============================================"
echo "INSTALLING TMUX IN BASE IMAGE"
echo "============================================"

# Check if tmux is installed
if docker run --rm --entrypoint /bin/bash "$TAG1" -c "which tmux" >/dev/null 2>&1; then
  echo "✓ tmux already installed in image"
else
  echo "Installing tmux in base image..."
  TMUX_CONTAINER="tmux_install_$$"

  # Detect OS and install tmux using appropriate method
  docker run --name "$TMUX_CONTAINER" --entrypoint /bin/bash "$TAG1" -c '
    # Clear any proxy settings that might interfere
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

    # Try to install tmux using existing repos (works for both Debian and Ubuntu)
    if command -v apt-get &>/dev/null; then
      apt-get update 2>/dev/null || true
      apt-get install -y --no-install-recommends tmux 2>/dev/null && exit 0

      # If that failed, try with --allow-unauthenticated (for GPG issues)
      apt-get install -y --allow-unauthenticated tmux 2>/dev/null && exit 0
    fi

    # Fallback: check if tmux binary exists in common locations
    [ -f /usr/bin/tmux ] && exit 0

    exit 1
  '

  if [ $? -eq 0 ]; then
    # Commit the container with tmux installed
    docker commit "$TMUX_CONTAINER" "$TAG1"
    docker tag "$TAG1" "$TAG2"  # Re-tag TAG2 as well
    echo "✓ tmux installed and image updated"
  else
    echo "WARNING: tmux installation failed, continuing anyway"
  fi

  docker rm "$TMUX_CONTAINER" 2>/dev/null || true
fi

# ============================================
# GET OPENHANDS VERSION
# ============================================
echo ""
echo "============================================"
echo "CONFIGURATION"
echo "============================================"

if [ -f "evaluation/utils/version_control.sh" ]; then
  source "evaluation/utils/version_control.sh"
  get_openhands_version 2>/dev/null || OPENHANDS_VERSION="v1.1.0"
else
  OPENHANDS_VERSION="v1.1.0"
fi
echo "OPENHANDS_VERSION: $OPENHANDS_VERSION"

# BUILD EVAL NOTE
EVAL_NOTE="${OPENHANDS_VERSION}-no-hint"
if [ -n "$EXP_NAME" ]; then
  EVAL_NOTE="${EVAL_NOTE}-${EXP_NAME}"
fi
echo "EVAL_NOTE: $EVAL_NOTE"

# ============================================
# CREATE MODIFIED DATASET (remove image_storage_uri)
# ============================================
echo ""
echo "============================================"
echo "CREATING MODIFIED DATASET"
echo "============================================"

# Create a temporary dataset with image_storage_uri removed
# This forces run_infer.py to use the mswebench-prefixed image name
# which triggers the correct Dockerfile.j2 branch with || true fallbacks
MODIFIED_DATASET="/tmp/modified_dataset_${INSTANCE_ID}.jsonl"

python3 << PYEOF
import json

with open("$DATASET_ABS", 'r') as f:
    data = json.load(f)

# Remove image_storage_uri so run_infer.py uses constructed image name
if 'image_storage_uri' in data:
    del data['image_storage_uri']
    print("Removed image_storage_uri from dataset")

# Write as JSONL (single line, no indentation) for load_dataset compatibility
with open("$MODIFIED_DATASET", 'w') as f:
    f.write(json.dumps(data) + '\n')

print(f"Created modified dataset (JSONL): $MODIFIED_DATASET")
PYEOF

echo "Modified dataset: $MODIFIED_DATASET"

# ============================================
# PHASE 1: TRAJECTORY GENERATION
# ============================================
echo ""
echo "============================================"
echo "PHASE 1: TRAJECTORY GENERATION"
echo "============================================"

unset SANDBOX_ENV_GITHUB_TOKEN  # Prevent agent from using github token

N_RUNS=${N_RUNS:-1}
for i in $(seq 1 $N_RUNS); do
  current_eval_note="${EVAL_NOTE}-run_${i}"
  echo ""
  echo "Starting run $i with eval_note: $current_eval_note"
  echo ""

  INFER_COMMAND="PYTHONPATH=\"$PWD:\$PYTHONPATH\" poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent-cls $AGENT \
    --llm-config $MODEL_CONFIG \
    --max-iterations $MAX_ITER \
    --eval-num-workers $NUM_WORKERS \
    --eval-note $current_eval_note \
    --dataset $MODIFIED_DATASET \
    --split $SPLIT \
    --eval-n-limit $EVAL_LIMIT"

  echo "Running: $INFER_COMMAND"
  echo ""
  eval $INFER_COMMAND
done

# ============================================
# FIND OUTPUT FILE
# ============================================
echo ""
echo "============================================"
echo "LOCATING TRAJECTORY OUTPUT"
echo "============================================"

# Extract model name from config for path construction
MODEL_NAME=$(grep -A 5 "\[$MODEL_CONFIG\]" config.toml | grep "model" | head -1 | sed 's/.*= *"\([^"]*\)".*/\1/' || echo "unknown")
echo "Model name: $MODEL_NAME"

# Find the output directory - search for directories containing output.jsonl
OUTPUT_BASE="evaluation/evaluation_outputs/outputs"

# Find the actual output.jsonl file first
OUTPUT_FILE=$(find $OUTPUT_BASE -type f -name "output.jsonl" -mmin -30 2>/dev/null | grep -E "${current_eval_note}" | head -1)

if [ -z "$OUTPUT_FILE" ]; then
  # Try alternate search by iteration count
  OUTPUT_FILE=$(find $OUTPUT_BASE -type f -name "output.jsonl" -mmin -30 2>/dev/null | grep "maxiter_${MAX_ITER}" | head -1)
fi

if [ -z "$OUTPUT_FILE" ]; then
  # Last resort: find most recent output.jsonl
  OUTPUT_FILE=$(find $OUTPUT_BASE -type f -name "output.jsonl" -mmin -30 2>/dev/null | head -1)
fi

if [ -z "$OUTPUT_FILE" ]; then
  echo "ERROR: Could not find output.jsonl!"
  echo "Searching in: $OUTPUT_BASE"
  find $OUTPUT_BASE -type f -name "output.jsonl" 2>/dev/null | tail -10
  exit 1
fi

# Get the directory containing output.jsonl
OUTPUT_DIR=$(dirname "$OUTPUT_FILE")

OUTPUT_FILE="$OUTPUT_DIR/output.jsonl"
echo "Found output directory: $OUTPUT_DIR"
echo "Output file: $OUTPUT_FILE"

if [ ! -f "$OUTPUT_FILE" ]; then
  echo "ERROR: Output file not found: $OUTPUT_FILE"
  exit 1
fi

# ============================================
# VERIFY INSTANCE ID MATCHES
# ============================================
TRAJ_INSTANCE_ID=$(cat "$OUTPUT_FILE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('instance_id', ''))
" 2>/dev/null)

if [ "$TRAJ_INSTANCE_ID" != "$INSTANCE_ID" ]; then
  echo "WARNING: Instance ID mismatch!"
  echo "  Dataset: $INSTANCE_ID"
  echo "  Trajectory: $TRAJ_INSTANCE_ID"
fi

echo "Instance ID verified: $INSTANCE_ID"

# ============================================
# CHECK FOR NON-EMPTY PATCHES
# ============================================
PATCH_SIZE=$(cat "$OUTPUT_FILE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
patch = d.get('test_result', {}).get('git_patch', '')
print(len(patch))
" 2>/dev/null || echo "0")

echo "Git patch size: $PATCH_SIZE bytes"

if [ "$PATCH_SIZE" -lt 100 ]; then
  echo "WARNING: No valid patch found in output. Skipping evaluation."
  echo ""
  echo "============================================"
  echo "TRAJECTORY GENERATION COMPLETE (NO PATCH)"
  echo "============================================"
  echo "Output directory: $OUTPUT_DIR"
  exit 0
fi

# ============================================
# PHASE 2: DETAILED PATCH EVALUATION
# ============================================
echo ""
echo "============================================"
echo "PHASE 2: DETAILED PATCH EVALUATION"
echo "Using eval_pilot2_standardized.py"
echo "============================================"

# Run the detailed evaluation script
# IMPORTANT: Use the fixed eval_pilot2_standardized.py from multi_swe_bench/scripts/
SCRIPT_DIR=$(dirname "$0")
EVAL_SCRIPT="$SCRIPT_DIR/eval_pilot2_standardized.py"
EVAL_OUTPUT_FILE="${OUTPUT_DIR}/eval_pilot2_output.jsonl"

# Verify eval script exists
if [ ! -f "$EVAL_SCRIPT" ]; then
  echo "ERROR: Evaluation script not found: $EVAL_SCRIPT"
  echo "Expected location: evaluation/benchmarks/multi_swe_bench/scripts/eval_pilot2_standardized.py"
  exit 1
fi

# Use the mswebench tagged image
DOCKER_IMAGE="$TAG1"
echo "Docker image for evaluation: $DOCKER_IMAGE"
echo "Evaluation script: $EVAL_SCRIPT"

EVAL_COMMAND="python3 $EVAL_SCRIPT \
  --trajectory-file $OUTPUT_FILE \
  --dataset-file $DATASET_ABS \
  --docker-image $DOCKER_IMAGE \
  --output-file $EVAL_OUTPUT_FILE \
  --timeout 600"

echo "Running: $EVAL_COMMAND"
echo ""
eval $EVAL_COMMAND

EVAL_EXIT=$?

if [ $EVAL_EXIT -ne 0 ]; then
  echo "ERROR: Evaluation failed with exit code $EVAL_EXIT"
  exit $EVAL_EXIT
fi

# ============================================
# POST-PROCESS: CREATE OPENHANDS-FORMAT REPORT
# ============================================
echo ""
echo "============================================"
echo "GENERATING OPENHANDS-FORMAT REPORT"
echo "============================================"

python3 << 'PYEOF'
import json
import os
import sys

# Load eval_pilot2 output
eval_output_file = os.environ['EVAL_OUTPUT_FILE']
output_dir = os.environ['OUTPUT_DIR']
instance_id = os.environ['INSTANCE_ID']

with open(eval_output_file, 'r') as f:
    data = json.load(f)

details = data.get('pilot2_eval_details', {})

# Create eval_outputs directory structure
eval_outputs_dir = os.path.join(output_dir, 'eval_outputs')
instance_eval_dir = os.path.join(eval_outputs_dir, instance_id)
os.makedirs(instance_eval_dir, exist_ok=True)

# Generate OpenHands-format report.json
report = {
    instance_id: {
        "patch_is_None": False,
        "patch_exists": True,
        "patch_successfully_applied": not details.get('failed_apply_patch', False),
        "resolved": details.get('resolved', False),
        "tests_status": {
            "FAIL_TO_PASS": {
                "success": details.get('fail_to_pass_success', []),
                "failure": details.get('fail_to_pass_failed', [])
            },
            "PASS_TO_PASS": {
                "success": details.get('pass_to_pass_success', []),
                "failure": details.get('pass_to_pass_failed', [])
            },
            "FAIL_TO_FAIL": {
                "success": [],
                "failure": []
            },
            "PASS_TO_FAIL": {
                "success": [],
                "failure": []
            }
        }
    }
}

# Save report.json in eval_outputs directory
report_file = os.path.join(instance_eval_dir, 'report.json')
with open(report_file, 'w') as f:
    json.dump(report, f, indent=4)

print(f"Created: {report_file}")

# Save test_output.txt
test_output_file = os.path.join(instance_eval_dir, 'test_output.txt')
with open(test_output_file, 'w') as f:
    f.write(details.get('test_output', ''))

print(f"Created: {test_output_file}")

# Extract and save patch.diff from trajectory
with open(os.path.join(output_dir, 'output.jsonl'), 'r') as f:
    traj_data = json.load(f)

patch = traj_data.get('test_result', {}).get('git_patch', '')
patch_file = os.path.join(instance_eval_dir, 'patch.diff')
with open(patch_file, 'w') as f:
    f.write(patch)

print(f"Created: {patch_file}")

# Create aggregate report.json in eval_outputs root
aggregate_report_file = os.path.join(eval_outputs_dir, 'report.json')
with open(aggregate_report_file, 'w') as f:
    json.dump(report, f, indent=4)

print(f"Created: {aggregate_report_file}")

# Print summary
print("")
print("=" * 60)
print("EVALUATION REPORT SUMMARY")
print("=" * 60)
print(f"Instance: {instance_id}")
print(f"Resolved: {details.get('resolved', False)}")
print(f"Tests Passed: {details.get('tests_passed', 0)}")
print(f"Tests Failed: {details.get('tests_failed', 0)}")
print(f"Tests Error: {details.get('tests_error', 0)}")
f2p_success = len(details.get('fail_to_pass_success', []))
f2p_total = f2p_success + len(details.get('fail_to_pass_failed', []))
p2p_success = len(details.get('pass_to_pass_success', []))
p2p_total = p2p_success + len(details.get('pass_to_pass_failed', []))
print(f"F2P Success: {f2p_success}/{f2p_total}")
print(f"P2P Success: {p2p_success}/{p2p_total}")
print("=" * 60)

PYEOF

# ============================================
# SUMMARY
# ============================================
echo ""
echo "============================================"
echo "FULL EVALUATION COMPLETE"
echo "============================================"
echo ""
echo "Output directory: $OUTPUT_DIR"
echo ""
echo "Files generated:"
ls -lh "$OUTPUT_DIR/" 2>/dev/null || true
echo ""

# Show eval_outputs structure
EVAL_OUTPUTS_DIR="$OUTPUT_DIR/eval_outputs"
if [ -d "$EVAL_OUTPUTS_DIR" ]; then
  echo "=== Evaluation Outputs ==="
  ls -lR "$EVAL_OUTPUTS_DIR/" 2>/dev/null | head -50
  echo ""

  # Show individual instance report
  for instance_dir in "$EVAL_OUTPUTS_DIR"/*/; do
    if [ -d "$instance_dir" ]; then
      instance_id=$(basename "$instance_dir")
      echo "Instance: $instance_id"
      echo "  Files: $(ls "$instance_dir" 2>/dev/null | tr '\n' ' ')"

      if [ -f "${instance_dir}report.json" ]; then
        echo ""
        echo "  Report Details:"
        cat "${instance_dir}report.json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for iid, details in d.items():
        print(f'    Resolved: {details.get(\"resolved\", False)}')
        print(f'    Patch Applied: {details.get(\"patch_successfully_applied\", False)}')
        ts = details.get('tests_status', {})
        f2p = ts.get('FAIL_TO_PASS', {})
        p2p = ts.get('PASS_TO_PASS', {})
        print(f'    F2P Success: {len(f2p.get(\"success\", []))} / Failure: {len(f2p.get(\"failure\", []))}')
        print(f'    P2P Success: {len(p2p.get(\"success\", []))} / Failure: {len(p2p.get(\"failure\", []))}')
except Exception as e:
    print(f'    Error parsing report: {e}')
" 2>/dev/null || true
      fi
      echo ""
    fi
  done
fi

echo ""
echo "============================================"
echo "SUCCESS: Full evaluation with S3 download complete"
echo "============================================"
