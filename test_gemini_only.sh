#!/bin/bash
#
# Test Pipeline with Gemini Only
#
# This script tests the trajectory generation pipeline using only Gemini API
# to validate everything works before getting other API keys.
#

set -e

echo "========================================="
echo "Testing VeloraTrajectories with Gemini"
echo "========================================="
echo

# Configuration
NUM_TASKS=2
OUTPUT_DIR="outputs/gemini_test"

# Change to VeloraTrajectories directory
cd "$(dirname "$0")"

# Step 1: Convert 2 sample tasks
echo "Step 1: Converting 2 sample tasks from CSV..."
python3 convert_csv_to_jsonl.py \
    --csv "repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv" \
    --output jaeger/VeloraHarness/data/gemini_test.jsonl \
    --limit 2

echo "✓ Tasks converted"
echo

# Step 2: Show sample task
echo "Step 2: Sample task preview..."
echo "----------------------------------------"
head -1 jaeger/VeloraHarness/data/gemini_test.jsonl | python3 -m json.tool | head -30
echo "... (truncated)"
echo "----------------------------------------"
echo

# Step 3: Generate trajectory with Gemini
echo "Step 3: Generating trajectories with Gemini..."
cd jaeger/VeloraHarness
export PYTHONPATH="$(pwd):$PYTHONPATH"
export DOCKER_BUILDKIT=0
export EVAL_DOCKER_IMAGE_PREFIX=mswebench
export USE_INSTANCE_IMAGE=true

mkdir -p "../../$OUTPUT_DIR"

poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent-cls CodeActAgent \
    --llm-config llm.gemini \
    --max-iterations 50 \
    --eval-num-workers 1 \
    --dataset data/gemini_test.jsonl \
    --split train \
    --eval-n-limit $NUM_TASKS \
    --eval-output-dir "../../$OUTPUT_DIR" \
    2>&1 | tee "../../$OUTPUT_DIR/test.log"

cd ../..

echo
echo "========================================="
echo "Test Complete!"
echo "========================================="
echo
echo "Results saved to: $OUTPUT_DIR/"
echo
echo "Files created:"
ls -lh "$OUTPUT_DIR/"
echo
echo "To view output:"
echo "  cat $OUTPUT_DIR/output.jsonl | python -m json.tool | less"
echo
echo "Next steps:"
echo "1. Review the output in $OUTPUT_DIR/output.jsonl"
echo "2. Check the log: $OUTPUT_DIR/test.log"
echo "3. If successful, get API keys for other models"
echo "4. Run full batch: ./generate_trajectories.sh"
