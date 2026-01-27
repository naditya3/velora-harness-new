#!/bin/bash
# run_velora_infer.sh - Modified run_infer.sh for Velora 200 tasks
# Usage: ./run_velora_infer.sh MODEL_CONFIG DATASET [EVAL_LIMIT] [MAX_ITER] [NUM_WORKERS]
# Example: ./run_velora_infer.sh llm.gpt ~/datasets/task.jsonl 1 200 1

set -eo pipefail

# ============================================
# VELORA-SPECIFIC ENVIRONMENT VARIABLES
# ============================================
export DOCKER_BUILDKIT=0                    # CRITICAL: Prevents buildx failures
export EVAL_DOCKER_IMAGE_PREFIX="mswebench/" # Our Docker image prefix
export USE_INSTANCE_IMAGE=true              # Use instance-specific images
export LANGUAGE=python                      # Our tasks are Python
export RUN_WITH_BROWSING=false
export USE_HINT_TEXT=false

# ============================================
# ARGUMENT PARSING
# ============================================
MODEL_CONFIG=$1
DATASET=$2
EVAL_LIMIT=${3:-1}        # Default: 1 task
MAX_ITER=${4:-200}        # Default: 200 iterations (increased from 50)
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

# ============================================
# DISPLAY CONFIGURATION
# ============================================
echo "============================================"
echo "VELORA TRAJECTORY GENERATION"
echo "============================================"
echo "MODEL_CONFIG: $MODEL_CONFIG"
echo "DATASET: $DATASET"
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

# ============================================
# GET OPENHANDS VERSION
# ============================================
# Source the version control script if available
if [ -f "evaluation/utils/version_control.sh" ]; then
  source "evaluation/utils/version_control.sh"
  get_openhands_version 2>/dev/null || OPENHANDS_VERSION="v1.1.0"
else
  OPENHANDS_VERSION="v1.1.0"
fi
echo "OPENHANDS_VERSION: $OPENHANDS_VERSION"

# ============================================
# BUILD EVAL NOTE
# ============================================
EVAL_NOTE="${OPENHANDS_VERSION}-no-hint"
if [ -n "$EXP_NAME" ]; then
  EVAL_NOTE="${EVAL_NOTE}-${EXP_NAME}"
fi

# ============================================
# RUN INFERENCE
# ============================================
unset SANDBOX_ENV_GITHUB_TOKEN  # Prevent agent from using github token

N_RUNS=${N_RUNS:-1}
for i in $(seq 1 $N_RUNS); do
  current_eval_note="${EVAL_NOTE}-run_${i}"
  echo ""
  echo "Starting run $i with eval_note: $current_eval_note"
  echo ""
  
  COMMAND="poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent-cls $AGENT \
    --llm-config $MODEL_CONFIG \
    --max-iterations $MAX_ITER \
    --eval-num-workers $NUM_WORKERS \
    --eval-note $current_eval_note \
    --dataset $DATASET \
    --split $SPLIT \
    --eval-n-limit $EVAL_LIMIT"
  
  echo "Running: $COMMAND"
  echo ""
  eval $COMMAND
done

echo ""
echo "============================================"
echo "TRAJECTORY GENERATION COMPLETE"
echo "============================================"

