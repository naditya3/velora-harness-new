#!/bin/bash
# =============================================================================
# Rollout Script for Client Tasks (Repomate Harness)
# =============================================================================
# End-to-end trajectory generation and evaluation for client tasks.
# Similar to OpenHands rollout_swegym.sh but adapted for Repomate harness.
#
# Usage:
#   ./rollout_client_task.sh <dataset_jsonl> <llm_config> [max_iterations] [output_dir]
#
# Example:
#   ./rollout_client_task.sh ~/datasets/task1.jsonl llm.gpt 50 ~/output
#
# Environment Variables:
#   VELORA_DIR    - Path to VeloraHarness (default: ~/VeloraHarness)
#   N_WORKERS     - Number of parallel workers (default: 1)
#   RUNTIME       - docker or remote (default: docker)
# =============================================================================

set -e

# ============= Arguments =============
DATASET=$1
LLM_CONFIG=${2:-"llm.gpt"}
MAX_ITER=${3:-50}
OUTPUT_DIR=${4:-"./client_eval_output"}

if [ -z "$DATASET" ]; then
    echo "Error: Dataset path required"
    echo ""
    echo "Usage: $0 <dataset_jsonl> [llm_config] [max_iterations] [output_dir]"
    echo ""
    echo "Arguments:"
    echo "  dataset_jsonl    Path to dataset JSONL file (required)"
    echo "  llm_config       LLM configuration name from config.toml (default: llm.gpt)"
    echo "  max_iterations   Max agent iterations (default: 50)"
    echo "  output_dir       Output directory (default: ./client_eval_output)"
    echo ""
    echo "Example:"
    echo "  $0 ~/datasets/sepal_ui.jsonl llm.gpt 50 ~/output"
    exit 1
fi

# ============= Configuration =============
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VELORA_DIR=${VELORA_DIR:-$(cd "$SCRIPT_DIR/../../../.." && pwd)}
N_WORKERS=${N_WORKERS:-1}

# Environment setup for client tasks
export DOCKER_BUILDKIT=0
export EVAL_DOCKER_IMAGE_PREFIX=mswebench
export USE_INSTANCE_IMAGE=true
export RUNTIME=${RUNTIME:-docker}

# ============= Create output directories =============
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DATASET_NAME=$(basename "$DATASET" .jsonl)

echo "=============================================="
echo "Client Task Rollout"
echo "=============================================="
echo "Dataset: $DATASET"
echo "LLM Config: $LLM_CONFIG"
echo "Max Iterations: $MAX_ITER"
echo "Output Dir: $OUTPUT_DIR"
echo "Workers: $N_WORKERS"
echo "VeloraHarness: $VELORA_DIR"
echo "=============================================="

# ============= Step 1: Trajectory Generation =============
echo ""
echo "=== Step 1: Generating Trajectory ==="
cd "$VELORA_DIR"

poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent-cls CodeActAgent \
    --llm-config "$LLM_CONFIG" \
    --max-iterations "$MAX_ITER" \
    --eval-num-workers "$N_WORKERS" \
    --dataset "$DATASET" \
    --split train \
    2>&1 | tee "$OUTPUT_DIR/trajectory_${TIMESTAMP}.log"

INFER_STATUS=$?

if [ $INFER_STATUS -ne 0 ]; then
    echo "ERROR: Trajectory generation failed with exit code $INFER_STATUS"
    exit $INFER_STATUS
fi

# Find the output file
OUTPUT_PATTERN="$VELORA_DIR/evaluation/evaluation_outputs/outputs/*${DATASET_NAME}*/**/output.jsonl"
TRAJECTORY_OUTPUT=$(ls -t $OUTPUT_PATTERN 2>/dev/null | head -1)

if [ -z "$TRAJECTORY_OUTPUT" ]; then
    echo "Error: Could not find trajectory output file"
    echo "Searched pattern: $OUTPUT_PATTERN"
    exit 1
fi

echo "Found trajectory output: $TRAJECTORY_OUTPUT"
cp "$TRAJECTORY_OUTPUT" "$OUTPUT_DIR/output.jsonl"

# ============= Step 2: Evaluation =============
echo ""
echo "=== Step 2: Running Evaluation ==="

python3 "$VELORA_DIR/evaluation/benchmarks/client_tasks/eval_client_harness.py" \
    --trajectory-output "$OUTPUT_DIR/output.jsonl" \
    --dataset "$DATASET" \
    --output-dir "$OUTPUT_DIR/eval_outputs" \
    --timeout 900 \
    2>&1 | tee "$OUTPUT_DIR/evaluation_${TIMESTAMP}.log"

EVAL_STATUS=$?

if [ $EVAL_STATUS -ne 0 ]; then
    echo "WARNING: Evaluation completed with exit code $EVAL_STATUS"
fi

# ============= Summary =============
echo ""
echo "=============================================="
echo "ROLLOUT COMPLETE!"
echo "=============================================="
echo ""
echo "Results:"
echo "  Trajectory: $OUTPUT_DIR/output.jsonl"
echo "  Evaluation: $OUTPUT_DIR/eval_outputs/"
echo "  Logs: $OUTPUT_DIR/*.log"
echo ""

if [ -f "$OUTPUT_DIR/eval_outputs/summary.json" ]; then
    echo "Summary:"
    cat "$OUTPUT_DIR/eval_outputs/summary.json"
fi

echo ""
echo "Per-instance reports: $OUTPUT_DIR/eval_outputs/<instance_id>/report.json"
echo "=============================================="

