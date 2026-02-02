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
export DOCKER_BUILDKIT=1                    # Enable buildx for better caching
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

# Extract SWE-Lancer specific fields if available
MONOLITH_IMAGE=$(cat "$DATASET_ABS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('monolith_image', ''))
" 2>/dev/null)

TASK_SPECIFIC_IMAGE=$(cat "$DATASET_ABS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('task_specific_image', ''))
" 2>/dev/null)

TEST_OUTPUT_PARSER=$(cat "$DATASET_ABS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('test_output_parser', ''))
" 2>/dev/null)

# Detect if this is a SWE-Lancer task
IS_SWELANCER=false
if [[ "$REPO" == *"Expensify"* ]] || [[ "$TEST_OUTPUT_PARSER" == *"swelancer"* ]] || [[ "$TEST_OUTPUT_PARSER" == *"playwright"* ]] || [[ -n "$MONOLITH_IMAGE" ]]; then
  IS_SWELANCER=true
  echo ""
  echo "============================================"
  echo "DETECTED SWE-LANCER TASK"
  echo "============================================"
  echo "Monolith Image: $MONOLITH_IMAGE"
  echo "Task Specific Image: $TASK_SPECIFIC_IMAGE"
  echo "Test Output Parser: $TEST_OUTPUT_PARSER"
  echo "USE_SWELANCER_MONOLITH: $USE_SWELANCER_MONOLITH"
fi

# Determine the Docker image to use
if [ "$IS_SWELANCER" = true ]; then
  if [ "$USE_SWELANCER_MONOLITH" = "true" ]; then
    # Use monolith image for all SWE-Lancer tasks
    DOCKER_IMAGE_TO_USE="$SWELANCER_MONOLITH_IMAGE"
    echo "Using SWE-Lancer monolith image: $DOCKER_IMAGE_TO_USE"
  elif [ -n "$TASK_SPECIFIC_IMAGE" ]; then
    # Use task-specific image
    DOCKER_IMAGE_TO_USE="$TASK_SPECIFIC_IMAGE"
    echo "Using SWE-Lancer task-specific image: $DOCKER_IMAGE_TO_USE"
  else
    DOCKER_IMAGE_TO_USE="$IMAGE_URI"
  fi
else
  DOCKER_IMAGE_TO_USE="$IMAGE_URI"
fi

# Construct S3 path - use the actual URI if it starts with s3://
# This allows the dataset to specify the exact S3 path to use
if [[ "$IMAGE_URI" == s3://* ]]; then
  # IMAGE_URI is already a full S3 path (e.g., s3://bucket/path/file.tar)
  S3_PATH="$IMAGE_URI"
  S3_IMAGE_FILE=$(basename "$IMAGE_URI")
  echo "Using S3 path from dataset: $S3_PATH"
elif [[ "$IMAGE_URI" == docker://* ]]; then
  # IMAGE_URI is a docker reference (e.g., docker://image:tag)
  DOCKER_REF=$(echo "$IMAGE_URI" | sed 's|docker://||')
  S3_IMAGE_FILE=""
  S3_PATH=""
  echo "Using Docker reference: $DOCKER_REF"
else
  # Legacy behavior: construct S3 path from image name
  REPO_PART=$(echo "$IMAGE_URI" | awk -F'/' '{print $NF}')
  REPO_NAME=$(echo "$REPO_PART" | cut -d':' -f1)
  COMMIT=$(echo "$REPO_PART" | cut -d':' -f2)
  S3_IMAGE_FILE="${REPO_NAME}-${COMMIT}.tar"
  # Default S3 bucket - can be overridden by environment variable
  S3_BUCKET="${S3_BUCKET:-kuberha-velora}"
  S3_PREFIX="${S3_PREFIX:-velora-files/images}"
  S3_PATH="s3://${S3_BUCKET}/${S3_PREFIX}/${S3_IMAGE_FILE}"
  echo "Constructed S3 path: $S3_PATH"
fi

echo "S3 Path: $S3_PATH"
echo "Local file: ${S3_IMAGE_FILE}"

# ============================================
# VERIFY AWS CONFIGURATION (if S3 download needed)
# ============================================
if [[ "$IMAGE_URI" == s3://* ]] || [[ -z "$DOCKER_IMAGE_TO_USE" ]]; then
  echo ""
  echo "============================================"
  echo "VERIFYING AWS CONFIGURATION"
  echo "============================================"
  
  # Check if AWS CLI is available
  if ! command -v aws &> /dev/null; then
    echo "ERROR: AWS CLI is not installed"
    echo "Please install AWS CLI: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
  fi
  
  # Check if AWS credentials are configured
  if ! aws sts get-caller-identity &> /dev/null; then
    echo "WARNING: AWS credentials may not be configured correctly"
    echo "Please ensure ~/.aws/credentials and ~/.aws/config exist"
    echo ""
    echo "Expected configuration:"
    echo "  ~/.aws/credentials:"
    echo "    [default]"
    echo "    aws_access_key_id = YOUR_ACCESS_KEY"
    echo "    aws_secret_access_key = YOUR_SECRET_KEY"
    echo ""
    echo "  ~/.aws/config:"
    echo "    [default]"
    echo "    region = us-east-1"
    echo ""
    echo "Continuing anyway - S3 download may fail..."
  else
    echo "✓ AWS credentials configured"
    aws sts get-caller-identity --query "Account" --output text 2>/dev/null | xargs -I {} echo "  Account: {}"
  fi
  
  # Test S3 access if we have a specific path
  if [[ "$IMAGE_URI" == s3://* ]]; then
    S3_BUCKET_NAME=$(echo "$IMAGE_URI" | sed 's|s3://||' | cut -d'/' -f1)
    echo "Testing access to S3 bucket: $S3_BUCKET_NAME"
    if aws s3 ls "s3://$S3_BUCKET_NAME" --max-items 1 &> /dev/null; then
      echo "✓ S3 bucket accessible: $S3_BUCKET_NAME"
    else
      echo "WARNING: Cannot access S3 bucket: $S3_BUCKET_NAME"
      echo "S3 download may fail. Please verify bucket name and permissions."
    fi
  fi
fi

# ============================================
# DOWNLOAD AND LOAD DOCKER IMAGE FROM S3
# ============================================
echo ""
echo "============================================"
echo "DOWNLOADING DOCKER IMAGE"
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
  
  echo "Loading Docker image..."
  docker load < "$local_file"
  
  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to load Docker image from: $local_file"
    return 1
  fi
  
  echo "✓ Image loaded successfully"
  
  # Keep the tar file for reuse (don't delete)
  # This avoids re-downloading for subsequent evaluations
  echo "✓ Keeping tar file for reuse: $local_file"
  
  return 0
}

# Handle SWE-Lancer images differently
if [ "$IS_SWELANCER" = true ] && ([ "$USE_SWELANCER_MONOLITH" = "true" ] || [ -n "$TASK_SPECIFIC_IMAGE" ]); then
  echo "SWE-Lancer mode: Checking if image exists..."
  
  # For SWE-Lancer, we pull from Docker Hub instead of S3
  if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "$DOCKER_IMAGE_TO_USE"; then
    echo "✓ SWE-Lancer Docker image already exists: $DOCKER_IMAGE_TO_USE"
  else
    echo "Pulling SWE-Lancer Docker image: $DOCKER_IMAGE_TO_USE"
    docker pull --platform linux/amd64 "$DOCKER_IMAGE_TO_USE"
    
    if [ $? -ne 0 ]; then
      echo "ERROR: Failed to pull SWE-Lancer Docker image"
      echo "Falling back to S3 download..."
      # Fall through to S3 download logic
    else
      echo "✓ SWE-Lancer image pulled successfully"
    fi
  fi
  
  # Set IMAGE_URI to the SWE-Lancer image for tagging
  IMAGE_URI="$DOCKER_IMAGE_TO_USE"

# Handle S3 path from dataset
elif [[ "$IMAGE_URI" == s3://* ]]; then
  echo "S3 mode: Downloading image from dataset-specified S3 path..."
  
  # Extract the expected image name after loading
  # The image name is determined by what's inside the tar file
  # We'll check after loading
  
  if [ -n "$S3_IMAGE_FILE" ] && [ -f "$S3_IMAGE_FILE" ]; then
    echo "✓ Tar file already exists locally: $S3_IMAGE_FILE"
    
    # Check if image is already loaded
    LOADED_IMAGE=$(docker load < "$S3_IMAGE_FILE" 2>&1 | grep -oP "Loaded image: \K.*" || true)
    if [ -n "$LOADED_IMAGE" ]; then
      echo "✓ Image loaded: $LOADED_IMAGE"
      IMAGE_URI="$LOADED_IMAGE"
    fi
  else
    download_and_load_from_s3 "$S3_PATH" "$S3_IMAGE_FILE"
    if [ $? -ne 0 ]; then
      exit 1
    fi
    
    # Get the loaded image name
    LOADED_IMAGE=$(docker images --format "{{.Repository}}:{{.Tag}}" | head -1)
    if [ -n "$LOADED_IMAGE" ]; then
      echo "✓ Detected loaded image: $LOADED_IMAGE"
      IMAGE_URI="$LOADED_IMAGE"
    fi
  fi

# Handle docker:// reference
elif [[ "$IMAGE_URI" == docker://* ]]; then
  DOCKER_REF=$(echo "$IMAGE_URI" | sed 's|docker://||')
  echo "Docker mode: Using docker reference $DOCKER_REF"
  
  if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "$DOCKER_REF"; then
    echo "✓ Docker image already exists: $DOCKER_REF"
  else
    echo "Pulling Docker image: $DOCKER_REF"
    docker pull --platform linux/amd64 "$DOCKER_REF"
    if [ $? -ne 0 ]; then
      echo "ERROR: Failed to pull Docker image: $DOCKER_REF"
      exit 1
    fi
  fi
  IMAGE_URI="$DOCKER_REF"

# Standard legacy S3 download
else
  if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "$IMAGE_URI"; then
    echo "✓ Docker image already loaded: $IMAGE_URI"
  else
    download_and_load_from_s3 "$S3_PATH" "$S3_IMAGE_FILE"
    if [ $? -ne 0 ]; then
      exit 1
    fi
  fi
fi

# ============================================
# TAG DOCKER IMAGE FOR OPENHANDS
# ============================================
echo ""
echo "============================================"
echo "TAGGING DOCKER IMAGE FOR OPENHANDS"
echo "============================================"

# Double tagging as per OpenHands requirements
# IMPORTANT: Docker requires repository names to be lowercase
REPO_M=$(echo "$REPO" | sed 's|/|_m_|g' | tr '[:upper:]' '[:lower:]')
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
RUN_NUMBER_OFFSET=${RUN_NUMBER_OFFSET:-0}
for i in $(seq 1 $N_RUNS); do
  actual_run_number=$((i + RUN_NUMBER_OFFSET))
  current_eval_note="${EVAL_NOTE}-run_${actual_run_number}"
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

# Determine Docker image for evaluation
if [ "$IS_SWELANCER" = true ]; then
  # For SWE-Lancer, use the appropriate image based on configuration
  if [ "$USE_SWELANCER_MONOLITH" = "true" ]; then
    DOCKER_IMAGE="$SWELANCER_MONOLITH_IMAGE"
    echo "Using SWE-Lancer monolith image for evaluation: $DOCKER_IMAGE"
  elif [ -n "$TASK_SPECIFIC_IMAGE" ]; then
    DOCKER_IMAGE="$TASK_SPECIFIC_IMAGE"
    echo "Using SWE-Lancer task-specific image for evaluation: $DOCKER_IMAGE"
  else
    DOCKER_IMAGE="$TAG1"
  fi
else
  # Use the mswebench tagged image for standard tasks
  DOCKER_IMAGE="$TAG1"
fi

echo "Docker image for evaluation: $DOCKER_IMAGE"
echo "Evaluation script: $EVAL_SCRIPT"

# Create run_instance.log
RUN_LOG="${OUTPUT_DIR}/eval_outputs/${INSTANCE_ID}/run_instance.log"
mkdir -p "$(dirname "$RUN_LOG")"

# Build evaluation command
EVAL_COMMAND="python3 $EVAL_SCRIPT \
  --trajectory-file $OUTPUT_FILE \
  --dataset-file $DATASET_ABS \
  --docker-image $DOCKER_IMAGE \
  --output-file $EVAL_OUTPUT_FILE \
  --timeout 600"

# Display SWE-Lancer specific configuration
if [ "$IS_SWELANCER" = true ]; then
  echo ""
  echo "SWE-Lancer Evaluation Configuration:"
  echo "  USE_SWELANCER_MONOLITH: $USE_SWELANCER_MONOLITH"
  echo "  Base Commit: $BASE_COMMIT"
  echo "  Test Output Parser: $TEST_OUTPUT_PARSER"
fi

echo ""
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
# IMPORTANT: Do NOT remove the base swelancer/unified or mswebench images - these are reused across runs!
if [ -n "$IMAGE_URI" ] && [ "$IMAGE_URI" != "$TAG1" ] && [ "$IMAGE_URI" != "$TAG2" ]; then
  # Skip removal if it's a base image we want to keep
  if [[ "$IMAGE_URI" == *"swelancer/unified"* ]] || [[ "$IMAGE_URI" == *"mswebench/swelancer"* ]]; then
    echo "  Keeping base image: $IMAGE_URI (reused across runs)"
  else
    docker rmi -f "$IMAGE_URI" 2>/dev/null && echo "✓ Removed: $IMAGE_URI" || echo "  (already removed or in use)"
  fi
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
