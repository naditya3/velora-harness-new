#!/usr/bin/env bash
set -eo pipefail

################################################################################
# Multi-Model Trajectory Generation Script
#
# Runs trajectory generation for multiple models on the repomate dataset
# Models: Claude Opus 4.6, GPT-5.2, Kimi K2.5, Qwen 3 Coder Plus
# Dataset: 75 samples from repomate_sample_for_rubric_annotations_with_data
#
# Author: Expert Coder with 36 years experience
# Date: 2026-02-06
################################################################################

# Navigate to VeloraHarness directory
cd /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness

# Configuration
DATASET="data/repomate_75_samples.jsonl"
SPLIT="train"
AGENT="CodeActAgent"
MAX_ITER=500
NUM_WORKERS=1
EVAL_NOTE="repomate_75_multimodel"

# Models to run (configured in config.toml)
MODELS=("opus" "gpt" "kimi" "qwen")
MODEL_NAMES=(
    "Claude Opus 4.6"
    "GPT-5.2"
    "Kimi K2.5"
    "Qwen 3 Coder Plus"
)

echo "================================================================================"
echo "  Multi-Model Trajectory Generation System"
echo "================================================================================"
echo "Dataset: repomate_75_samples.jsonl"
echo "Number of samples: 75"
echo "Max iterations: $MAX_ITER"
echo "Agent: $AGENT"
echo "Models:"
for i in "${!MODELS[@]}"; do
    echo "  [$((i+1))] ${MODEL_NAMES[$i]} (${MODELS[$i]})"
done
echo "================================================================================"
echo ""

# Check if dataset exists, if not create it
if [ ! -f "$DATASET" ]; then
    echo "⚠️  Dataset not found. Creating it now..."
    echo ""

    # Run the preparation script
    python3 scripts/prepare_repomate_dataset.py 75

    if [ $? -ne 0 ]; then
        echo "❌ Failed to create dataset"
        exit 1
    fi

    echo ""
    echo "✓ Dataset created successfully"
    echo ""
fi

# Verify dataset
SAMPLE_COUNT=$(wc -l < "$DATASET")
echo "Dataset verification:"
echo "  Path: $DATASET"
echo "  Samples: $SAMPLE_COUNT"
echo ""

if [ $SAMPLE_COUNT -eq 0 ]; then
    echo "❌ Dataset is empty!"
    exit 1
fi

# Set environment
export PYTHONPATH=$(pwd):$PYTHONPATH
export USE_INSTANCE_IMAGE=false

# Create log directory
LOG_DIR="../../outputs/multimodel_logs_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"

echo "Log directory: $LOG_DIR"
echo ""

# Function to run a single model
run_model() {
    local model_config=$1
    local model_name=$2
    local log_file="$LOG_DIR/${model_config}_trajectory.log"

    echo "================================================================================"
    echo "  Starting: $model_name"
    echo "================================================================================"
    echo "Model config: $model_config"
    echo "Log file: $log_file"
    echo "Start time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    # Run trajectory generation
    sg docker -c "python3 evaluation/benchmarks/swe_bench/run_infer.py \
        --agent-cls $AGENT \
        --llm-config $model_config \
        --max-iterations $MAX_ITER \
        --eval-num-workers $NUM_WORKERS \
        --dataset $DATASET \
        --split $SPLIT \
        --eval-note ${EVAL_NOTE}_${model_config} \
        2>&1 | tee $log_file"

    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        echo ""
        echo "✓ $model_name completed successfully"
    else
        echo ""
        echo "✗ $model_name failed with exit code: $exit_code"
        echo "  Check log: $log_file"
    fi

    echo "End time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "================================================================================"
    echo ""

    return $exit_code
}

# Ask user for execution mode
echo "================================================================================"
echo "Execution Mode Selection"
echo "================================================================================"
echo "How would you like to run the models?"
echo ""
echo "  [1] Sequential - Run models one after another (safer, slower)"
echo "  [2] Parallel - Run all models simultaneously (faster, resource intensive)"
echo "  [3] Custom - Select specific models to run"
echo ""
read -p "Enter your choice (1-3): " -r EXEC_MODE
echo ""

case $EXEC_MODE in
    1)
        echo "Running in SEQUENTIAL mode..."
        echo ""

        for i in "${!MODELS[@]}"; do
            run_model "${MODELS[$i]}" "${MODEL_NAMES[$i]}"

            # Small delay between models
            if [ $i -lt $((${#MODELS[@]} - 1)) ]; then
                echo "Waiting 5 seconds before next model..."
                sleep 5
            fi
        done
        ;;

    2)
        echo "Running in PARALLEL mode..."
        echo ""
        echo "⚠️  WARNING: This will consume significant resources!"
        read -p "Are you sure you want to continue? (y/n): " -r CONFIRM

        if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
            echo "Cancelled."
            exit 0
        fi

        echo ""

        # Start all models in background
        PIDS=()
        for i in "${!MODELS[@]}"; do
            run_model "${MODELS[$i]}" "${MODEL_NAMES[$i]}" &
            PIDS+=($!)
            sleep 2  # Small delay to stagger starts
        done

        # Wait for all to complete
        echo "Waiting for all models to complete..."
        for i in "${!PIDS[@]}"; do
            wait ${PIDS[$i]}
            echo "  ✓ Model $((i+1))/${#MODELS[@]} finished"
        done
        ;;

    3)
        echo "Custom Model Selection"
        echo ""
        echo "Available models:"
        for i in "${!MODELS[@]}"; do
            echo "  [$((i+1))] ${MODEL_NAMES[$i]}"
        done
        echo ""
        read -p "Enter model numbers to run (space-separated, e.g., '1 3'): " -r SELECTED

        # Parse selected models
        SELECTED_MODELS=()
        SELECTED_NAMES=()
        for num in $SELECTED; do
            idx=$((num - 1))
            if [ $idx -ge 0 ] && [ $idx -lt ${#MODELS[@]} ]; then
                SELECTED_MODELS+=("${MODELS[$idx]}")
                SELECTED_NAMES+=("${MODEL_NAMES[$idx]}")
            fi
        done

        echo ""
        echo "Running selected models:"
        for name in "${SELECTED_NAMES[@]}"; do
            echo "  - $name"
        done
        echo ""

        for i in "${!SELECTED_MODELS[@]}"; do
            run_model "${SELECTED_MODELS[$i]}" "${SELECTED_NAMES[$i]}"

            if [ $i -lt $((${#SELECTED_MODELS[@]} - 1)) ]; then
                sleep 5
            fi
        done
        ;;

    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac

echo ""
echo "================================================================================"
echo "  ✓ ALL TRAJECTORY GENERATION COMPLETE"
echo "================================================================================"
echo ""
echo "Output locations:"
echo "  Base: evaluation/evaluation_outputs/outputs/"
for model in "${MODELS[@]}"; do
    echo "  - data__repomate_75_samples.jsonl-train/CodeActAgent/${EVAL_NOTE}_${model}*"
done
echo ""
echo "Logs directory: $LOG_DIR"
echo ""
echo "To view results:"
echo "  ls -lh evaluation/evaluation_outputs/outputs/data__repomate_75_samples.jsonl-train/CodeActAgent/"
echo ""
echo "Session completed: $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================================"
