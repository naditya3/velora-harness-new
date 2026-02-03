#!/bin/bash
# run_full_eval_swe.sh - Complete Velora evaluation pipeline with S3 Docker download
#
# This script:
#   1. Downloads Docker image from S3 based on dataset
#   2. Loads and tags the image for OpenHands
#   3. Runs trajectory generation (run_infer.py)
#   4. Runs patch evaluation (eval_standardized_swe.py)
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
# Usage: ./run_full_eval_swe.sh MODEL_CONFIG DATASET [EVAL_LIMIT] [MAX_ITER] [NUM_WORKERS]
# Example: ./run_full_eval_swe.sh llm.gpt data/task.jsonl 1 30 1
#
# Environment variables:
#   RUN_ID       - If set, creates a single run with this ID (used by batch worker)
#   N_RUNS       - Number of runs to generate (default: 1, ignored if RUN_ID is set)
#   EXP_NAME     - Experiment name suffix for output directory

set -eo pipefail

# ============================================
# VELORA-SPECIFIC ENVIRONMENT VARIABLES
# ============================================
export DOCKER_BUILDKIT=0                    # CRITICAL: Prevents buildx failures
export EVAL_DOCKER_IMAGE_PREFIX="mswebench" # Our Docker image prefix
export USE_INSTANCE_IMAGE=true              # Use instance-specific images
export USE_SWELANCER_MONOLITH=false         # Disable SWE-Lancer monolith mode (use task-specific images)
export DEFAULT_REASONING_EFFORT_HIGH_THINKING_BUDGET=24576  # Unlock full 24K thinking budget for Gemini 3 Pro
# LANGUAGE is now extracted from dataset (supports python, php, go, java, etc.)
export RUN_WITH_BROWSING=false
export USE_HINT_TEXT=false
export PYTHONPATH="$(pwd):$PYTHONPATH"    # CRITICAL: Ensure openhands module is found

# Unset runtime container image to force fresh build
unset RUNTIME_CONTAINER_IMAGE

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

# Extract language from dataset
LANGUAGE=$(cat "$DATASET_ABS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('language', 'python'))
" 2>/dev/null)
export LANGUAGE

echo "Image URI: $IMAGE_URI"
echo "Repo: $REPO"
echo "Base Commit: $BASE_COMMIT"
echo "Language: $LANGUAGE"

# Handle S3 path - support both full S3 paths and legacy format
# DIRECT S3 PATH: Supports any S3 bucket (e.g., s3://rfp-coding-q1/Images/SWE-HARD/...)
# LEGACY FORMAT: Constructs path to s3://kuberha-velora/velora-files/images/
if [[ "$IMAGE_URI" == s3://* ]]; then
  # image_storage_uri is already a full S3 path from any bucket
  # Examples:
  #   - s3://rfp-coding-q1/Images/SWE-HARD/shopify__liquid-*.tar
  #   - s3://kuberha-velora/velora-files/images/*.tar
  S3_PATH="$IMAGE_URI"
  S3_IMAGE_FILE=$(basename "$S3_PATH")
  # For S3 paths, the loaded image name is velora/{instance_id}:base
  LOADED_IMAGE_NAME="velora/${INSTANCE_ID}:base"
  echo "S3 Path (direct): $S3_PATH"
else
  # Legacy format: construct S3 path from IMAGE_URI parts (kuberha-velora only)
  REPO_PART=$(echo "$IMAGE_URI" | awk -F'/' '{print $NF}')
  REPO_NAME=$(echo "$REPO_PART" | cut -d':' -f1)
  COMMIT=$(echo "$REPO_PART" | cut -d':' -f2)
  S3_IMAGE_FILE="${REPO_NAME}-${COMMIT}.tar"
  S3_PATH="s3://kuberha-velora/velora-files/images/${S3_IMAGE_FILE}"
  LOADED_IMAGE_NAME="$IMAGE_URI"
  echo "S3 Path (constructed): $S3_PATH"
fi

echo "Local file: ${S3_IMAGE_FILE}"
echo "Expected image after load: $LOADED_IMAGE_NAME"

# ============================================
# DOWNLOAD AND LOAD DOCKER IMAGE FROM S3
# ============================================
echo ""
echo "============================================"
echo "DOWNLOADING DOCKER IMAGE FROM S3"
echo "============================================"

# The mswebench tag is what OpenHands will use
TAG1="mswebench/sweb.eval.x86_64.${INSTANCE_ID}:latest"

# Check if mswebench-tagged image already exists with tmux and wget
if docker run --rm --entrypoint /bin/bash "$TAG1" -c "which tmux && which wget" >/dev/null 2>&1; then
  echo "✓ Docker image already loaded and tagged: $TAG1"
  LOADED_IMAGE_NAME="$TAG1"
else
  echo "Downloading from S3..."
  aws s3 cp "$S3_PATH" "$S3_IMAGE_FILE"

  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to download Docker image from S3"
    exit 1
  fi

  echo "✓ Downloaded $(du -h "$S3_IMAGE_FILE" | cut -f1)"

  echo "Loading Docker image..."
  # Capture the actual image name from docker load output
  LOAD_OUTPUT=$(docker load < "$S3_IMAGE_FILE" 2>&1)
  LOAD_EXIT_CODE=$?

  if [ $LOAD_EXIT_CODE -ne 0 ]; then
    echo "ERROR: Failed to load Docker image"
    echo "$LOAD_OUTPUT"
    exit 1
  fi

  # Parse the actual image name from "Loaded image: <image_name>" output
  LOADED_IMAGE_NAME=$(echo "$LOAD_OUTPUT" | grep -oP 'Loaded image: \K.*' | head -1)
  
  if [ -z "$LOADED_IMAGE_NAME" ]; then
    echo "WARNING: Could not parse image name from docker load output"
    echo "$LOAD_OUTPUT"
    # Fallback to expected name
    LOADED_IMAGE_NAME="velora/${INSTANCE_ID}:base"
  fi

  echo "✓ Image loaded: $LOADED_IMAGE_NAME"

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
# TAG1 already defined above: mswebench/sweb.eval.x86_64.${INSTANCE_ID}:latest
TAG2="mswebench/${REPO_M}:pr-${INSTANCE_ID}"

echo "Source image: $LOADED_IMAGE_NAME"
echo "Tag 1: $TAG1"
echo "Tag 2: $TAG2"

# Only tag if source image is different from TAG1 (not already tagged)
if [ "$LOADED_IMAGE_NAME" != "$TAG1" ]; then
  echo "Tagging image..."
  docker tag "$LOADED_IMAGE_NAME" "$TAG1"
  docker tag "$LOADED_IMAGE_NAME" "$TAG2"
  echo "✓ Image tagged successfully"
else
  echo "✓ Image already tagged correctly"
  # Ensure TAG2 also exists
  docker tag "$TAG1" "$TAG2" 2>/dev/null || true
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

# Function to fix Docker image with tmux and wget (handles both Debian and Ubuntu)
fix_docker_image_with_dependencies() {
  local SOURCE_IMAGE=$1
  local TARGET_TAG=$2

  echo "Fixing Docker image: installing tmux and wget..."

  # Create a temporary container
  CONTAINER_ID=$(docker run -d --entrypoint /bin/bash "$SOURCE_IMAGE" -c "sleep 300")

  # Try to install tmux - use bookworm stable to avoid usrmerge issues
  docker exec "$CONTAINER_ID" bash -c '
    # Clear proxy settings
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
    export http_proxy="" https_proxy=""
    
    # Remove problematic sources
    rm -f /etc/apt/sources.list.d/*.list 2>/dev/null || true
    
    TMUX_INSTALLED=0
    
    # Approach 1: Use bookworm (stable) to avoid usrmerge/trixie issues
    # Only install tmux, wget and their direct dependencies, no upgrades
    if [ "$TMUX_INSTALLED" -eq 0 ]; then
      echo "Trying bookworm repos (no upgrades)..."
      cat > /etc/apt/sources.list << "DEBEOF"
deb http://deb.debian.org/debian bookworm main
DEBEOF
      # Use -o to avoid upgrading existing packages
      if apt-get update 2>/dev/null && \
         apt-get install -y --no-install-recommends --no-upgrade tmux wget 2>/dev/null; then
        TMUX_INSTALLED=1
        echo "✓ tmux and wget installed using bookworm repos"
      fi
    fi
    
    # Approach 2: Download and install tmux and wget binaries directly
    # Use bullseye (Debian 11) packages to match base image glibc version
    if [ "$TMUX_INSTALLED" -eq 0 ]; then
      echo "Trying direct download of tmux, wget and their dependencies (bullseye)..."
      cd /tmp
      # First try bullseye packages (glibc 2.31 compatible)
      echo "Downloading bullseye (Debian 11) packages for glibc compatibility..."
      curl -sLO http://ftp.debian.org/debian/pool/main/t/tmux/tmux_3.1c-1+deb11u1_amd64.deb 2>/dev/null
      # tmux needs libevent-2.1-7 (provides libevent-2.1.so.7), NOT just libevent-core
      curl -sLO http://ftp.debian.org/debian/pool/main/libe/libevent/libevent-2.1-7_2.1.12-stable-1_amd64.deb 2>/dev/null
      curl -sLO http://ftp.debian.org/debian/pool/main/libu/libutempter/libutempter0_1.2.1-2_amd64.deb 2>/dev/null
      curl -sLO http://ftp.debian.org/debian/pool/main/w/wget/wget_1.21-1+deb11u1_amd64.deb 2>/dev/null
      
      # Install tmux dependencies first
      if ls libevent*.deb >/dev/null 2>&1; then
        echo "Installing libevent (provides libevent-2.1.so.7 for tmux)..."
        dpkg --force-depends -i libevent*.deb 2>/dev/null || true
      fi
      if ls libutempter*.deb >/dev/null 2>&1; then
        echo "Installing libutempter0..."
        dpkg --force-depends -i libutempter*.deb 2>/dev/null || true
      fi
      
      # Now install tmux
      if ls tmux*.deb >/dev/null 2>&1; then
        echo "Installing tmux..."
        dpkg --force-depends -i tmux*.deb 2>/dev/null || true
        if which tmux >/dev/null 2>&1; then
          # Test if tmux actually runs (check for glibc issues)
          if tmux -V 2>&1 | grep -q "^tmux"; then
            TMUX_INSTALLED=1
            echo "✓ tmux installed and working via direct download"
            tmux -V
          else
            echo "tmux binary installed but not working, checking libs..."
            ldd /usr/bin/tmux 2>/dev/null | grep "not found" || true
          fi
        fi
      fi
      if [ -f wget*.deb ]; then
        dpkg --force-depends -i wget*.deb 2>/dev/null || true
        if which wget >/dev/null 2>&1; then
          echo "✓ wget installed via direct download"
        fi
      fi
      
      # If wget still not available, create a curl-based wget wrapper
      if ! which wget >/dev/null 2>&1; then
        echo "Creating wget wrapper using curl..."
        echo "#!/bin/bash" > /usr/local/bin/wget
        echo "# wget wrapper using curl - handles basic wget usage" >> /usr/local/bin/wget
        echo "URL=\"\"" >> /usr/local/bin/wget
        echo "OUTPUT=\"\"" >> /usr/local/bin/wget
        echo "while [[ \$# -gt 0 ]]; do" >> /usr/local/bin/wget
        echo "  case \$1 in" >> /usr/local/bin/wget
        echo "    -O) OUTPUT=\"\$2\"; shift 2;;" >> /usr/local/bin/wget
        echo "    -o) OUTPUT=\"\$2\"; shift 2;;" >> /usr/local/bin/wget
        echo "    -q|--quiet) shift;;" >> /usr/local/bin/wget
        echo "    -*) shift;;" >> /usr/local/bin/wget
        echo "    *) URL=\"\$1\"; shift;;" >> /usr/local/bin/wget
        echo "  esac" >> /usr/local/bin/wget
        echo "done" >> /usr/local/bin/wget
        echo "if [ -n \"\$OUTPUT\" ]; then" >> /usr/local/bin/wget
        echo "  exec curl -fsSL -o \"\$OUTPUT\" \"\$URL\"" >> /usr/local/bin/wget
        echo "else" >> /usr/local/bin/wget
        echo "  exec curl -fsSLO \"\$URL\"" >> /usr/local/bin/wget
        echo "fi" >> /usr/local/bin/wget
        chmod +x /usr/local/bin/wget
        if [ -x /usr/local/bin/wget ]; then
          echo "✓ wget wrapper created using curl"
        fi
      fi
    fi
    
    # Approach 3: Build minimal screen as tmux alternative (last resort)
    if [ "$TMUX_INSTALLED" -eq 0 ]; then
      echo "tmux installation failed, checking if screen is available..."
      if which screen >/dev/null 2>&1; then
        # Create tmux symlink to screen as fallback
        ln -sf $(which screen) /usr/bin/tmux 2>/dev/null || true
        TMUX_INSTALLED=1
        echo "✓ Using screen as tmux fallback"
      fi
    fi
    
    # Check if tmux and wget were installed
    if which tmux >/dev/null 2>&1 && (which wget >/dev/null 2>&1 || [ -x /usr/local/bin/wget ]); then
      echo "✓ tmux and wget successfully available"
      exit 0
    elif which tmux >/dev/null 2>&1; then
      echo "✓ tmux available, wget missing but continuing"
      exit 0
    else
      echo "WARNING: Could not install tmux - OpenHands may not work properly"
      exit 1
    fi
  '

  if [ $? -eq 0 ]; then
    # Commit the fixed container as a new image
    # CRITICAL: Clear ENTRYPOINT to prevent conflicts with OpenHands runtime
    # The base image may have ENTRYPOINT [/bin/bash] which causes the action server
    # command to be interpreted as a bash script, breaking the runtime
    docker commit --change='ENTRYPOINT []' --change='CMD []' "$CONTAINER_ID" "$TARGET_TAG"
    echo "✓ Fixed image committed as: $TARGET_TAG (ENTRYPOINT cleared)"
  else
    echo "WARNING: Failed to install dependencies, continuing with original image"
    docker tag "$SOURCE_IMAGE" "$TARGET_TAG"
  fi

  # Cleanup
  docker stop "$CONTAINER_ID" >/dev/null 2>&1 || true
  docker rm "$CONTAINER_ID" >/dev/null 2>&1 || true
}

# Check if tmux and wget are installed AND WORKING (verify tmux runs, not just exists)
if docker run --rm --entrypoint /bin/bash "$TAG1" -c "tmux -V && (which wget || [ -x /usr/local/bin/wget ])" >/dev/null 2>&1; then
  echo "✓ tmux and wget already installed and working in image"
else
  echo "Installing tmux and wget in base image..."
  fix_docker_image_with_dependencies "$TAG1" "$TAG1"
  docker tag "$TAG1" "$TAG2"  # Re-tag TAG2 as well
fi

# ============================================
# VERIFY LANGUAGE ENVIRONMENT (Ruby/Bundler for Ruby repos)
# ============================================
echo ""
echo "============================================"
echo "VERIFYING LANGUAGE ENVIRONMENT"
echo "============================================"

if [ "$LANGUAGE" = "Ruby" ]; then
  echo "Checking Ruby environment in Docker image..."

  # Check Ruby
  if docker run --rm --entrypoint /bin/bash "$TAG1" -c "which ruby" >/dev/null 2>&1; then
    RUBY_VERSION=$(docker run --rm --entrypoint /bin/bash "$TAG1" -c "ruby --version 2>&1" | head -1)
    echo "✓ Ruby installed: $RUBY_VERSION"
  else
    echo "✗ ERROR: Ruby not found in Docker image"
    echo "The Docker image must have Ruby pre-installed for Ruby projects"
    exit 1
  fi

  # Check Bundler
  if docker run --rm --entrypoint /bin/bash "$TAG1" -c "which bundle" >/dev/null 2>&1; then
    BUNDLER_VERSION=$(docker run --rm --entrypoint /bin/bash "$TAG1" -c "bundle --version 2>&1" | head -1)
    echo "✓ Bundler installed: $BUNDLER_VERSION"
  else
    echo "✗ ERROR: Bundler not found in Docker image"
    echo "The Docker image must have Bundler pre-installed for Ruby projects"
    exit 1
  fi

  echo "✓ Ruby environment verified successfully"
else
  echo "Language: $LANGUAGE (skipping Ruby-specific checks)"
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
# CREATE MODIFIED DATASET (set image_storage_uri to mswebench tag)
# ============================================
echo ""
echo "============================================"
echo "CREATING MODIFIED DATASET"
echo "============================================"

# Create a temporary dataset with image_storage_uri set to the mswebench tag
# This tells run_infer.py to use the locally tagged image
MODIFIED_DATASET="/tmp/modified_dataset_${INSTANCE_ID}.jsonl"

python3 << PYEOF
import json

with open("$DATASET_ABS", 'r') as f:
    data = json.load(f)

# Replace image_storage_uri with the mswebench tag (local Docker image)
old_uri = data.get('image_storage_uri', 'N/A')
new_uri = "$TAG1"
data['image_storage_uri'] = new_uri
print(f"Updated image_storage_uri: {old_uri} -> {new_uri}")

with open("$MODIFIED_DATASET", 'w') as f:
    json.dump(data, f)

print(f"Created modified dataset: $MODIFIED_DATASET")
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

# Support for batch evaluation: RUN_ID environment variable
# If RUN_ID is set, use it for unique output paths (single run)
# Otherwise, use N_RUNS loop for multiple runs
if [ -n "$RUN_ID" ]; then
  # Single run with specific ID (used by batch worker)
  current_eval_note="${EVAL_NOTE}-run_${RUN_ID}"
  echo ""
  echo "Starting run $RUN_ID with eval_note: $current_eval_note"
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
  # Change to repository root to run poetry command
  cd ../../../../..
  eval $INFER_COMMAND
  # Return to script directory
  cd evaluation/benchmarks/multi_swe_bench/scripts/swe-hard
else
  # Multiple runs (N_RUNS loop)
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
    # Change to repository root to run poetry command
    cd ../../../../..
    eval $INFER_COMMAND
    # Return to script directory
    cd evaluation/benchmarks/multi_swe_bench/scripts/swe-hard
  done
fi

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
echo "Using eval_standardized_swe.py"
echo "============================================"

# Run the detailed evaluation script
# Use eval_pilot2_standardized.py (unified version with all parsers)
SCRIPT_DIR=$(dirname "$0")
EVAL_SCRIPT="$SCRIPT_DIR/eval_pilot2_standardized.py"
EVAL_OUTPUT_FILE="${OUTPUT_DIR}/eval_standardized_output.jsonl"

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

# Run evaluation with --output-dir to create the full eval_outputs structure
EVAL_COMMAND="python3 $EVAL_SCRIPT \
  --trajectory-file $OUTPUT_FILE \
  --dataset-file $DATASET_ABS \
  --docker-image $DOCKER_IMAGE \
  --output-file $EVAL_OUTPUT_FILE \
  --output-dir $OUTPUT_DIR \
  --timeout 600"

echo "Running: $EVAL_COMMAND"
echo ""
eval $EVAL_COMMAND

EVAL_EXIT=$?

if [ $EVAL_EXIT -ne 0 ]; then
  echo "ERROR: Evaluation failed with exit code $EVAL_EXIT"
  exit $EVAL_EXIT
fi

# Note: eval_pilot2_standardized.py now creates the full eval_outputs structure:
#   eval_outputs/
#   ├── report.json
#   └── <instance_id>/
#       ├── patch.diff
#       ├── report.json
#       ├── test_output.txt
#       ├── run_instance.log
#       └── eval.sh
#   eval_summary.json

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
