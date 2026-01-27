#!/bin/bash
# run_full_eval.sh - Complete Velora evaluation pipeline
# 
# This script runs BOTH:
#   1. Trajectory generation (run_infer.py) - Generates git patches
#   2. Patch evaluation (eval_infer.py) - Applies patches and runs tests
#
# Output structure:
#   evaluation_outputs/outputs/.../
#   ├── output.jsonl              ← Trajectory + git_patch
#   ├── output.swebench_eval.jsonl ← Evaluation results
#   ├── metadata.json             ← Run metadata
#   ├── llm_completions/          ← LLM responses
#   └── output.swebench_eval.logs/ ← Evaluation logs per instance
#
# Usage: ./run_full_eval.sh MODEL_CONFIG DATASET [EVAL_LIMIT] [MAX_ITER] [NUM_WORKERS]
# Example: ./run_full_eval.sh llm.gpt ~/datasets/task.jsonl 1 200 1

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
MAX_ITER=${4:-200}        # Default: 200 iterations
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
echo "VELORA FULL EVALUATION PIPELINE"
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
# GET OPENHANDS VERSION
# ============================================
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

# Convert dataset path to the format used in output directory
DATASET_DIR_NAME=$(echo "$DATASET_ABS" | tr '/' '_' | sed 's/^_//')
echo "Dataset dir pattern: $DATASET_DIR_NAME"

# Find the output directory
OUTPUT_BASE="evaluation/evaluation_outputs/outputs"
OUTPUT_DIR=$(find $OUTPUT_BASE -type d -name "*${current_eval_note}*" 2>/dev/null | head -1)

if [ -z "$OUTPUT_DIR" ]; then
  # Try alternate search
  OUTPUT_DIR=$(find $OUTPUT_BASE -type d -name "*maxiter_${MAX_ITER}*" -newer /tmp 2>/dev/null | head -1)
fi

if [ -z "$OUTPUT_DIR" ]; then
  echo "ERROR: Could not find output directory!"
  echo "Searching in: $OUTPUT_BASE"
  find $OUTPUT_BASE -type d -name "*run_*" 2>/dev/null | tail -5
  exit 1
fi

OUTPUT_FILE="$OUTPUT_DIR/output.jsonl"
echo "Found output directory: $OUTPUT_DIR"
echo "Output file: $OUTPUT_FILE"

if [ ! -f "$OUTPUT_FILE" ]; then
  echo "ERROR: Output file not found: $OUTPUT_FILE"
  exit 1
fi

# ============================================
# PHASE 2: PATCH EVALUATION
# ============================================
echo ""
echo "============================================"
echo "PHASE 2: PATCH EVALUATION"
echo "============================================"

# Check if there are any non-empty patches
PATCH_COUNT=$(cat "$OUTPUT_FILE" | python3 -c "
import sys, json
count = 0
for line in sys.stdin:
    d = json.loads(line)
    patch = d.get('test_result', {}).get('git_patch', '')
    if patch and patch.strip():
        count += 1
print(count)
" 2>/dev/null || echo "0")

echo "Number of tasks with patches: $PATCH_COUNT"

if [ "$PATCH_COUNT" -eq 0 ]; then
  echo "WARNING: No patches found in output. Skipping evaluation."
  echo ""
  echo "============================================"
  echo "TRAJECTORY GENERATION COMPLETE (NO PATCHES)"
  echo "============================================"
  echo "Output directory: $OUTPUT_DIR"
  exit 0
fi

# Run the simple evaluation script
SCRIPT_DIR=$(dirname "$0")
EVAL_COMMAND="python3 $SCRIPT_DIR/simple_eval.py \
  --input-file $OUTPUT_FILE \
  --dataset $DATASET_ABS \
  --timeout 600"

echo "Running: $EVAL_COMMAND"
echo ""
eval $EVAL_COMMAND

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
ls -la "$OUTPUT_DIR/" 2>/dev/null || true
echo ""

# Check for eval outputs directory
EVAL_OUTPUTS_DIR="$OUTPUT_DIR/eval_outputs"
if [ -d "$EVAL_OUTPUTS_DIR" ]; then
  echo "Evaluation outputs:"
  ls -la "$EVAL_OUTPUTS_DIR/" 2>/dev/null || true
  echo ""
  
  # Show individual instance results
  for instance_dir in "$EVAL_OUTPUTS_DIR"/*/; do
    if [ -d "$instance_dir" ]; then
      instance_id=$(basename "$instance_dir")
      echo "Instance: $instance_id"
      echo "  Files: $(ls "$instance_dir" 2>/dev/null | tr '\n' ' ')"
      if [ -f "${instance_dir}report.json" ]; then
        cat "${instance_dir}report.json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f\"  Resolved: {d.get('resolved', False)}\")
print(f\"  Failed Apply: {d.get('failed_apply_patch', False)}\")
print(f\"  Error: {d.get('error_eval', False)}\")
" 2>/dev/null || true
      fi
      echo ""
    fi
  done
fi

# Show summary
SUMMARY_FILE="$OUTPUT_DIR/eval_summary.json"
if [ -f "$SUMMARY_FILE" ]; then
  echo "=== EVALUATION SUMMARY ==="
  cat "$SUMMARY_FILE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f\"Total: {d.get('total', 0)}\")
print(f\"Resolved: {d.get('resolved', 0)}\")
print(f\"Failed Apply: {d.get('failed_apply_patch', 0)}\")
print(f\"Errors: {d.get('error_eval', 0)}\")
" 2>/dev/null || cat "$SUMMARY_FILE"
fi

echo ""
echo "============================================"

