#!/usr/bin/env bash
set -eo pipefail

#############################################################################
# Gemini Pass@1 - Generate 1 trajectory per instance (5 instances total)
#
# This runs 5 separate evaluations, one for each instance
# Each instance gets exactly 1 trajectory (pass@1)
#############################################################################

# Configuration
DATASET="data/gemini_pass1_5instances.jsonl"
MODEL="gemini"
AGENT="CodeActAgent"
MAX_ITER=50
NUM_WORKERS=1

echo "========================================="
echo "Gemini Pass@1 Trajectory Generation"
echo "========================================="
echo "Dataset: 5 instances"
echo "Strategy: 1 trajectory per instance"
echo "Total trajectories: 5"
echo "========================================="
echo ""

# Set environment
export PYTHONPATH=$(pwd):$PYTHONPATH
export USE_INSTANCE_IMAGE=false

# Create output directory
mkdir -p ../../outputs/gemini_pass1_logs

# Get all instance IDs from the dataset
echo "Extracting instance IDs..."
INSTANCE_IDS=($(python3 -c "
import json
with open('$DATASET') as f:
    for line in f:
        data = json.loads(line)
        print(data['instance_id'])
"))

TOTAL=${#INSTANCE_IDS[@]}
echo "Found $TOTAL instances to process"
echo ""

# Process each instance separately
for i in "${!INSTANCE_IDS[@]}"; do
    INSTANCE_ID="${INSTANCE_IDS[$i]}"
    RUN_NUM=$((i + 1))

    echo "========================================="
    echo "Processing Instance $RUN_NUM/$TOTAL"
    echo "========================================="
    echo "Instance ID: $INSTANCE_ID"
    echo ""

    LOG_FILE="../../outputs/gemini_pass1_logs/instance_${RUN_NUM}_${INSTANCE_ID}.log"
    EVAL_NOTE="gemini_pass1_instance${RUN_NUM}"

    echo "Starting trajectory generation..."
    echo "Log: $LOG_FILE"
    echo ""

    # Run evaluation for this single instance
    sg docker -c "python3 evaluation/benchmarks/multi_swe_bench/run_infer.py \
        --agent-cls $AGENT \
        --llm-config $MODEL \
        --max-iterations $MAX_ITER \
        --eval-num-workers $NUM_WORKERS \
        --dataset $DATASET \
        --split train \
        --eval-note $EVAL_NOTE \
        > $LOG_FILE 2>&1" &

    PID=$!
    echo "Started with PID: $PID"

    # Wait for this instance to complete before starting next
    wait $PID
    EXIT_CODE=$?

    if [ $EXIT_CODE -eq 0 ]; then
        echo "✓ Instance $RUN_NUM completed successfully"
    else
        echo "✗ Instance $RUN_NUM failed with exit code: $EXIT_CODE"
        echo "  Check log: $LOG_FILE"
    fi
    echo ""

    # Small delay between instances
    sleep 2
done

echo ""
echo "========================================="
echo "✓ All 5 instances processed!"
echo "========================================="
echo ""
echo "Output locations:"
echo "  evaluation/evaluation_outputs/outputs/data__gemini_pass1_5instances.jsonl-train/"
echo ""
echo "Logs directory:"
echo "  ../../outputs/gemini_pass1_logs/"
echo ""
echo "Check results:"
echo "  ls -lh evaluation/evaluation_outputs/outputs/data__gemini_pass1_5instances.jsonl-train/CodeActAgent/"
echo "========================================="
