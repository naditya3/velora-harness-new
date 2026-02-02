#!/bin/bash
# run_full_eval_with_s3.sh - Complete Velora evaluation pipeline with S3 Docker download
#
# This script:
#   1. Downloads Docker image from S3 based on dataset
#   2. Loads and tags the image for OpenHands (with tmux fix if needed)
#   3. Runs trajectory generation (run_infer.py)
#   4. Runs patch evaluation (eval_pilot2_standardized.py)
#   5. Creates OpenHands-format reports
#
# Output structure:
#   evaluation_outputs/outputs/.../
#   ├── output.jsonl              ← Trajectory + git_patch
#   ├── metadata.json             ← Run metadata
#   ├── llm_completions/          ← LLM responses
#   ├── logs/                     ← Execution logs
#   ├── eval_pilot2_output.jsonl  ← Raw evaluation results
#   └── eval_outputs/             ← Evaluation results
#       ├── report.json           ← Aggregate report
#       └── <instance_id>/
#           ├── report.json       ← Detailed test breakdown
#           ├── patch.diff        ← Applied patch
#           ├── test_output.txt   ← Full test output
#           └── run_instance.log  ← Execution log
#
# Usage: ./run_full_eval_with_s3.sh MODEL_CONFIG DATASET [EVAL_LIMIT] [MAX_ITER] [NUM_WORKERS] [AGENT]
# Example: ./run_full_eval_with_s3.sh llm.gemini3 /path/to/dataset.jsonl 1 30 1

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

# Note: RUNTIME_CONTAINER_IMAGE="skip" removed - it causes "invalid reference format" errors

# Add current directory to PYTHONPATH for openhands module resolution
export PYTHONPATH="$(pwd):$PYTHONPATH"

# ============================================
# PRE-RUN RESOURCE CHECK AND CLEANUP
# ============================================
echo "============================================"
echo "PRE-RUN RESOURCE CHECK AND CLEANUP"
echo "============================================"

# Function to check available disk space (returns available GB)
check_disk_space() {
  local available_kb=$(df -k . | tail -1 | awk '{print $4}')
  local available_gb=$((available_kb / 1024 / 1024))
  echo $available_gb
}

# Function to check available memory (returns available GB)
check_memory() {
  local available_kb=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
  local available_gb=$((available_kb / 1024 / 1024))
  echo $available_gb
}

# Check disk space before proceeding
DISK_GB=$(check_disk_space)
echo "Available disk space: ${DISK_GB}GB"

# Minimum required space: 10GB
MIN_DISK_GB=10

if [ "$DISK_GB" -lt "$MIN_DISK_GB" ]; then
  echo "WARNING: Low disk space (${DISK_GB}GB < ${MIN_DISK_GB}GB). Running aggressive cleanup..."

  # Stop all running containers (except critical ones)
  echo "Stopping all openhands-related containers..."
  docker ps -q --filter "name=openhands" | xargs -r docker stop 2>/dev/null || true
  docker ps -q --filter "name=sweb" | xargs -r docker stop 2>/dev/null || true

  # Remove all stopped containers
  echo "Removing stopped containers..."
  docker container prune -f 2>/dev/null || true

  # Remove all OpenHands runtime images aggressively
  echo "Removing OpenHands runtime images..."
  docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -E "(ghcr.io/openhands/runtime|openhands-runtime)" | xargs -r docker rmi -f 2>/dev/null || true

  # Remove dangling images
  echo "Removing dangling images..."
  docker image prune -f 2>/dev/null || true

  # Remove unused volumes
  echo "Removing unused volumes..."
  docker volume prune -f 2>/dev/null || true

  # Run full system prune
  echo "Running full Docker system prune..."
  docker system prune -f --volumes 2>/dev/null || true

  # Re-check disk space
  DISK_GB=$(check_disk_space)
  echo "Available disk space after cleanup: ${DISK_GB}GB"

  if [ "$DISK_GB" -lt "$MIN_DISK_GB" ]; then
    echo "ERROR: Still not enough disk space after cleanup (${DISK_GB}GB < ${MIN_DISK_GB}GB)"
    echo "Please free up disk space manually before running evaluation."
    exit 1
  fi
fi

# Check memory before proceeding
MEM_GB=$(check_memory)
echo "Available memory: ${MEM_GB}GB"

# Minimum required memory: 4GB
MIN_MEM_GB=4

if [ "$MEM_GB" -lt "$MIN_MEM_GB" ]; then
  echo "WARNING: Low memory (${MEM_GB}GB < ${MIN_MEM_GB}GB). Killing stale processes..."

  # Kill any stale Python/OpenHands processes that might be hogging memory
  pkill -f "run_infer" 2>/dev/null || true
  pkill -f "openhands" 2>/dev/null || true

  # Stop any running openhands containers
  docker ps -q --filter "name=openhands" | xargs -r docker stop 2>/dev/null || true

  # Re-check memory
  sleep 2
  MEM_GB=$(check_memory)
  echo "Available memory after cleanup: ${MEM_GB}GB"
fi

# Always do a basic cleanup before each run to prevent accumulation
echo "Running pre-run Docker cleanup..."
docker container prune -f 2>/dev/null || true
docker image prune -f 2>/dev/null || true

# Clean up any leftover runtime images from previous runs
echo "Cleaning up old OpenHands runtime images..."
OLD_RUNTIME_IMAGES=$(docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -E "ghcr.io/openhands/runtime" | head -10 || true)
if [ -n "$OLD_RUNTIME_IMAGES" ]; then
  echo "Found old runtime images, removing..."
  echo "$OLD_RUNTIME_IMAGES" | xargs -r docker rmi -f 2>/dev/null || true
  echo "✓ Old runtime images cleaned up"
fi

echo "✓ Pre-run checks complete"
echo ""

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
  echo "ERROR: MODEL_CONFIG is required (e.g., llm.gpt, llm.claude, llm.gemini3)"
  echo "Usage: $0 MODEL_CONFIG DATASET [EVAL_LIMIT] [MAX_ITER] [NUM_WORKERS] [AGENT]"
  echo ""
  echo "Examples:"
  echo "  $0 llm.gemini3 /path/to/dataset.jsonl 1 30 1"
  echo "  $0 llm.gpt /path/to/dataset.jsonl 1 200 1"
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

# Export INSTANCE_ID for later use in Python scripts
export INSTANCE_ID

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

# Use image_storage_uri directly as S3 path (supports multiple S3 buckets)
if [[ "$IMAGE_URI" == s3://* ]]; then
  # image_storage_uri is already a full S3 path
  S3_PATH="$IMAGE_URI"
  S3_IMAGE_FILE=$(basename "$S3_PATH")
  echo "S3 Path (from image_storage_uri): $S3_PATH"
else
  # Legacy format: construct S3 path from image_storage_uri parts
  REPO_PART=$(echo "$IMAGE_URI" | awk -F'/' '{print $NF}')
  REPO_NAME=$(echo "$REPO_PART" | cut -d':' -f1)
  COMMIT=$(echo "$REPO_PART" | cut -d':' -f2)
  S3_IMAGE_FILE="${REPO_NAME}-${COMMIT}.tar"
  S3_PATH="s3://kuberha-velora/velora-files/images/${S3_IMAGE_FILE}"
  echo "S3 Path (constructed): $S3_PATH"
fi

echo "Local file: ${S3_IMAGE_FILE}"

# ============================================
# DOWNLOAD AND LOAD DOCKER IMAGE FROM S3
# ============================================
echo ""
echo "============================================"
echo "DOWNLOADING DOCKER IMAGE FROM S3"
echo "============================================"

# Determine the expected Docker image name after loading
# Determine the expected Docker image name after loading
# For S3 paths, the image inside the tar is named velora/{instance_id}:base
if [[ "$IMAGE_URI" == s3://* ]]; then
  SOURCE_IMAGE="velora/${INSTANCE_ID}:base"
  echo "Expected image after load: $SOURCE_IMAGE"
else
  SOURCE_IMAGE="$IMAGE_URI"
  echo "Expected image: $SOURCE_IMAGE"
fi

# For S3 paths, the image inside the tar is named velora/{instance_id}:base
if [[ "$IMAGE_URI" == s3://* ]]; then
  # S3 path format - image inside tar is velora/{instance_id}:base
  VELORA_IMAGE="velora/${INSTANCE_ID}:base"
  SOURCE_IMAGE="$VELORA_IMAGE"
  echo "Expected image after load: $VELORA_IMAGE"
else
  # Legacy format - IMAGE_URI is the actual docker image name
  SOURCE_IMAGE="$IMAGE_URI"
  echo "Expected image: $SOURCE_IMAGE"
fi

# Check if image already exists
if docker images --format "{{.Repository}}:{{.Tag}}" | grep -qF "$SOURCE_IMAGE"; then
  echo "✓ Docker image already loaded: $SOURCE_IMAGE"
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

# Function to fix Docker image with tmux
fix_docker_image_with_tmux() {
  local SOURCE_IMAGE=$1
  local TARGET_TAG=$2

  echo "Fixing Docker image: installing tmux..."

  # Create a temporary container
  CONTAINER_ID=$(docker run -d --entrypoint /bin/bash "$SOURCE_IMAGE" -c "sleep 300")

  # Fix apt sources and install tmux
  docker exec "$CONTAINER_ID" bash -c '
    # Fix apt sources for Ubuntu Jammy
    cat > /etc/apt/sources.list << "EOF"
deb http://archive.ubuntu.com/ubuntu/ jammy main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ jammy-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ jammy-security main restricted universe multiverse
EOF
    # Clear proxy settings
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
    export http_proxy="" https_proxy=""
    # Update and install tmux
    apt-get update && apt-get install -y tmux
  '

  if [ $? -eq 0 ]; then
    # Commit the fixed container as a new image
    docker commit "$CONTAINER_ID" "$TARGET_TAG"
    echo "✓ Fixed image committed as: $TARGET_TAG"
  else
    echo "WARNING: Failed to install tmux, continuing with original image"
    docker tag "$SOURCE_IMAGE" "$TARGET_TAG"
  fi

  # Cleanup
  docker stop "$CONTAINER_ID" >/dev/null 2>&1 || true
  docker rm "$CONTAINER_ID" >/dev/null 2>&1 || true
}

# Check if TAG1 already exists and has tmux (fixed image)
if docker run --rm --entrypoint /bin/bash "$TAG1" -c "which tmux" >/dev/null 2>&1; then
  echo "✓ Fixed image already exists with tmux - skipping re-tag"
else
  # Check if the source image has tmux
  if docker run --rm --entrypoint /bin/bash "$IMAGE_URI" -c "which tmux" >/dev/null 2>&1; then
    echo "Source image has tmux, tagging directly..."
    docker tag "$IMAGE_URI" "$TAG1"
    docker tag "$IMAGE_URI" "$TAG2"
    echo "✓ Image tagged successfully"
  else
    echo "Source image missing tmux - fixing..."
    fix_docker_image_with_tmux "$IMAGE_URI" "$TAG1"
    docker tag "$TAG1" "$TAG2"
    echo "✓ Fixed image tagged successfully"
  fi
fi

# Verify tags
echo ""
echo "Verifying tags:"
docker images | grep -E "(${INSTANCE_ID}|${REPO_M})" | head -5

# ============================================
# CLEAN UP OLD RUNTIME IMAGES (if any)
# ============================================
echo ""
echo "Cleaning up old OpenHands runtime images..."
OLD_RUNTIME_IMAGES=$(docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep "ghcr.io/openhands/runtime" | head -5 || true)
if [ -n "$OLD_RUNTIME_IMAGES" ]; then
  echo "Found old runtime images, removing..."
  echo "$OLD_RUNTIME_IMAGES" | xargs -r docker rmi -f 2>/dev/null || true
  echo "✓ Old runtime images cleaned up"
else
  echo "✓ No old runtime images to clean"
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

  INFER_COMMAND="poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent-cls $AGENT \
    --llm-config $MODEL_CONFIG \
    --max-iterations $MAX_ITER \
    --eval-num-workers $NUM_WORKERS \
    --eval-note $current_eval_note \
    --dataset $DATASET_ABS \
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

# Find the actual output.jsonl file first - try with current_eval_note AND instance_id
OUTPUT_FILE=$(find $OUTPUT_BASE -type f -name "output.jsonl" 2>/dev/null | grep "${INSTANCE_ID}" | grep -E "${current_eval_note}" | head -1)

if [ -z "$OUTPUT_FILE" ]; then
  # Try alternate search by instance_id and iteration count
  OUTPUT_FILE=$(find $OUTPUT_BASE -type f -name "output.jsonl" 2>/dev/null | grep "${INSTANCE_ID}" | grep "maxiter_${MAX_ITER}" | head -1)
fi

if [ -z "$OUTPUT_FILE" ]; then
  # Try search by instance_id only
  OUTPUT_FILE=$(find $OUTPUT_BASE -type f -name "output.jsonl" 2>/dev/null | grep "${INSTANCE_ID}" | head -1)
fi

if [ -z "$OUTPUT_FILE" ]; then
  # Last resort: find most recent output.jsonl (sorted by modification time)
  OUTPUT_FILE=$(find $OUTPUT_BASE -type f -name "output.jsonl" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
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

# Export OUTPUT_DIR for later use
export OUTPUT_DIR

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

# Export for Python script
export EVAL_OUTPUT_FILE

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

# Create run_instance.log
RUN_LOG="${OUTPUT_DIR}/eval_outputs/${INSTANCE_ID}/run_instance.log"
mkdir -p "$(dirname "$RUN_LOG")"

EVAL_COMMAND="python3 $EVAL_SCRIPT \
  --trajectory-file $OUTPUT_FILE \
  --dataset-file $DATASET_ABS \
  --docker-image $DOCKER_IMAGE \
  --output-file $EVAL_OUTPUT_FILE \
  --timeout 600"

echo "Running: $EVAL_COMMAND"
echo ""

# Run evaluation and capture output to log
eval $EVAL_COMMAND 2>&1 | tee "$RUN_LOG"

EVAL_EXIT=${PIPESTATUS[0]}

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

# Run Python script with proper environment variables
python3 << PYEOF
import json
import os
import sys

# Get environment variables
eval_output_file = os.environ.get('EVAL_OUTPUT_FILE', '')
output_dir = os.environ.get('OUTPUT_DIR', '')
instance_id = os.environ.get('INSTANCE_ID', '')

if not eval_output_file or not output_dir or not instance_id:
    print("ERROR: Missing environment variables")
    print(f"  EVAL_OUTPUT_FILE: {eval_output_file}")
    print(f"  OUTPUT_DIR: {output_dir}")
    print(f"  INSTANCE_ID: {instance_id}")
    sys.exit(1)

# Load eval_pilot2 output
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

REPORT_EXIT=$?
if [ $REPORT_EXIT -ne 0 ]; then
  echo "WARNING: Report generation had issues (exit code: $REPORT_EXIT)"
fi

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
      inst_id=$(basename "$instance_dir")
      echo "Instance: $inst_id"
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

# ============================================
# POST-RUN CLEANUP
# ============================================
echo ""
echo "============================================"
echo "POST-RUN CLEANUP"
echo "============================================"

# Clean up the Docker images created for this evaluation
# This ensures the next evaluation can run without disk space issues

echo "Cleaning up evaluation Docker images..."

# Remove the tagged images (TAG1 and TAG2)
if [ -n "$TAG1" ]; then
  docker rmi -f "$TAG1" 2>/dev/null && echo "✓ Removed: $TAG1" || echo "  (already removed or in use)"
fi

if [ -n "$TAG2" ]; then
  docker rmi -f "$TAG2" 2>/dev/null && echo "✓ Removed: $TAG2" || echo "  (already removed or in use)"
fi

# Remove the original source image if it's different from TAG1/TAG2
if [ -n "$IMAGE_URI" ] && [ "$IMAGE_URI" != "$TAG1" ] && [ "$IMAGE_URI" != "$TAG2" ]; then
  docker rmi -f "$IMAGE_URI" 2>/dev/null && echo "✓ Removed: $IMAGE_URI" || echo "  (already removed or in use)"
fi

# Clean up any OpenHands runtime images created during this run
echo "Cleaning up OpenHands runtime images..."
RUNTIME_IMAGES=$(docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -E "(ghcr.io/openhands/runtime|openhands-runtime)" || true)
if [ -n "$RUNTIME_IMAGES" ]; then
  echo "$RUNTIME_IMAGES" | xargs -r docker rmi -f 2>/dev/null || true
  echo "✓ Runtime images cleaned up"
else
  echo "✓ No runtime images to clean"
fi

# Clean up dangling images (untagged images)
echo "Cleaning up dangling images..."
docker image prune -f 2>/dev/null || true
echo "✓ Dangling images cleaned up"

# Show remaining disk usage
echo ""
echo "Docker disk usage after cleanup:"
docker system df 2>/dev/null | head -5 || true

echo ""
echo "============================================"
echo "SUCCESS: Full evaluation with S3 download complete"
echo "============================================"
