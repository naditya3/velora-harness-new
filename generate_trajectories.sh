#!/bin/bash
#
# Generate Trajectories for Multiple Models
#
# This script generates trajectories for all configured models:
# - Claude Opus 4.6
# - Kimi K2
# - Qwen3 Coder
# - GPT-5.2
#
# Usage:
#   ./generate_trajectories.sh <dataset_path> <num_tasks> <output_base_dir>
#
# Example:
#   ./generate_trajectories.sh data/tasks.jsonl 10 outputs/

set -e

# Configuration
DATASET=${1:-"data/tasks.jsonl"}
NUM_TASKS=${2:-10}
OUTPUT_BASE=${3:-"outputs"}
MAX_ITERATIONS=500
NUM_WORKERS=1

# Models to evaluate
MODELS=("opus" "kimi" "qwen" "gpt")
MODEL_NAMES=("Claude_Opus_4.6" "Kimi_2.5" "Qwen3_Coder" "GPT_4o")

# Change to VeloraHarness directory
cd "$(dirname "$0")/jaeger/VeloraHarness"
export PYTHONPATH="$(pwd):$PYTHONPATH"

# Set environment variables
export DOCKER_BUILDKIT=0
export EVAL_DOCKER_IMAGE_PREFIX=mswebench
export USE_INSTANCE_IMAGE=true

echo "========================================="
echo "Trajectory Generation Configuration"
echo "========================================="
echo "Dataset: $DATASET"
echo "Number of tasks: $NUM_TASKS"
echo "Max iterations: $MAX_ITERATIONS"
echo "Output base: $OUTPUT_BASE"
echo "Models: ${MODEL_NAMES[@]}"
echo "========================================="
echo

# Create output directory
mkdir -p "$OUTPUT_BASE"

# Function to run trajectory generation for a model
run_model() {
    local model_key=$1
    local model_name=$2

    echo "========================================="
    echo "Starting: $model_name"
    echo "========================================="

    # Create model-specific output directory
    local output_dir="$OUTPUT_BASE/$model_name"
    mkdir -p "$output_dir"

    # Run trajectory generation
    poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
        --agent-cls CodeActAgent \
        --llm-config llm.$model_key \
        --max-iterations $MAX_ITERATIONS \
        --eval-num-workers $NUM_WORKERS \
        --dataset "$DATASET" \
        --split train \
        --eval-n-limit $NUM_TASKS \
        --eval-output-dir "$output_dir" \
        2>&1 | tee "$output_dir/generation.log"

    echo "✓ Completed: $model_name"
    echo "  Output: $output_dir/output.jsonl"
    echo
}

# Sequential execution for all models
for i in "${!MODELS[@]}"; do
    run_model "${MODELS[$i]}" "${MODEL_NAMES[$i]}"
done

echo "========================================="
echo "All trajectory generation complete!"
echo "========================================="
echo
echo "Output directories:"
for model_name in "${MODEL_NAMES[@]}"; do
    echo "  - $OUTPUT_BASE/$model_name/"
done
echo
echo "Next steps:"
echo "1. Review trajectories in output.jsonl files"
echo "2. Run evaluation with: ./evaluate_trajectories.sh"
