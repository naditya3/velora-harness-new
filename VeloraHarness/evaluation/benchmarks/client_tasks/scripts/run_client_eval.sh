#!/bin/bash
# =============================================================================
# Client Task Runner: Trajectory + Evaluation
# =============================================================================
# This script runs end-to-end trajectory generation and evaluation for client tasks
# following the OpenHands output format.
#
# Usage:
#   ./run_client_eval.sh <dataset_jsonl> <llm_config> [max_iterations] [output_dir]
#
# Example:
#   ./run_client_eval.sh ~/datasets/task1.jsonl llm.gpt 50 ~/output
#
# Output structure (matching OpenHands format):
#   <output_dir>/
#   ├── output.jsonl              # Trajectory output
#   └── eval_outputs/
#       └── <instance_id>/
#           ├── report.json       # F2P/P2P evaluation results
#           ├── patch.diff        # Generated patch
#           ├── test_output.txt   # Raw test output
#           └── eval.sh           # Evaluation script used
# =============================================================================

set -e

# ============= Arguments =============
DATASET=$1
LLM_CONFIG=${2:-"llm.gpt"}
MAX_ITER=${3:-50}
OUTPUT_DIR=${4:-"./client_eval_output"}

if [ -z "$DATASET" ]; then
    echo "Error: Dataset path required"
    echo "Usage: $0 <dataset_jsonl> [llm_config] [max_iterations] [output_dir]"
    exit 1
fi

# ============= Configuration =============
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR=${BASE_DIR:-~/SWETEs7}
OPENHANDS_DIR="$BASE_DIR/OpenHands"
VELORA_DIR="$BASE_DIR/Velora2Pilot2"

# Environment setup
export DOCKER_BUILDKIT=0
export EVAL_DOCKER_IMAGE_PREFIX=mswebench
export USE_INSTANCE_IMAGE=true

# ============= Create output directories =============
mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/eval_outputs"

echo "=============================================="
echo "Client Task Runner"
echo "=============================================="
echo "Dataset: $DATASET"
echo "LLM Config: $LLM_CONFIG"
echo "Max Iterations: $MAX_ITER"
echo "Output Dir: $OUTPUT_DIR"
echo "=============================================="

# ============= Step 1: Run Trajectory Generation =============
echo ""
echo "=== Step 1: Generating Trajectory ==="
cd "$OPENHANDS_DIR"

# Get dataset filename for output path
DATASET_NAME=$(basename "$DATASET" .jsonl)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent-cls CodeActAgent \
    --llm-config "$LLM_CONFIG" \
    --max-iterations "$MAX_ITER" \
    --eval-num-workers 1 \
    --dataset "$DATASET" \
    --split train \
    --eval-n-limit 100 \
    2>&1 | tee "$OUTPUT_DIR/trajectory_generation.log"

# Find the output file
# OpenHands outputs to: evaluation/evaluation_outputs/outputs/<dataset_path>-<split>/CodeActAgent/<model>_maxiter_<iter>/output.jsonl
OUTPUT_PATTERN="$OPENHANDS_DIR/evaluation/evaluation_outputs/outputs/*${DATASET_NAME}*/**/output.jsonl"
TRAJECTORY_OUTPUT=$(ls -t $OUTPUT_PATTERN 2>/dev/null | head -1)

if [ -z "$TRAJECTORY_OUTPUT" ]; then
    echo "Error: Could not find trajectory output file"
    exit 1
fi

echo "Found trajectory output: $TRAJECTORY_OUTPUT"
cp "$TRAJECTORY_OUTPUT" "$OUTPUT_DIR/output.jsonl"

# ============= Step 2: Run Evaluation =============
echo ""
echo "=== Step 2: Running Evaluation ==="
cd "$VELORA_DIR/scripts"

python3 eval_client_harness.py \
    --trajectory-output "$OUTPUT_DIR/output.jsonl" \
    --dataset "$DATASET" \
    --output-dir "$OUTPUT_DIR/eval_outputs" \
    --timeout 900 \
    2>&1 | tee "$OUTPUT_DIR/evaluation.log"

# ============= Step 3: Generate OpenHands-style report.json =============
echo ""
echo "=== Step 3: Generating OpenHands-format Reports ==="

python3 << 'PYTHON_SCRIPT'
import json
import os
import sys

output_dir = os.environ.get('OUTPUT_DIR', './client_eval_output')
eval_dir = os.path.join(output_dir, 'eval_outputs')

# Read our evaluation results
eval_results_file = os.path.join(eval_dir, 'eval_results.jsonl')
if not os.path.exists(eval_results_file):
    print(f"Error: {eval_results_file} not found")
    sys.exit(1)

with open(eval_results_file, 'r') as f:
    for line in f:
        result = json.loads(line)
        instance_id = result['instance_id']
        
        # Create instance directory
        instance_dir = os.path.join(eval_dir, str(instance_id))
        os.makedirs(instance_dir, exist_ok=True)
        
        # Create OpenHands-style report.json
        report = {
            instance_id: {
                "patch_is_None": False,
                "patch_exists": True,
                "patch_successfully_applied": result.get('patch_applied', False),
                "resolved": result.get('resolved', False),
                "tests_status": {
                    "FAIL_TO_PASS": {
                        "success": [k for k, v in result.get('f2p_status', {}).items() if v in ['PASSED', 'XFAIL']],
                        "failure": [k for k, v in result.get('f2p_status', {}).items() if v not in ['PASSED', 'XFAIL']]
                    },
                    "PASS_TO_PASS": {
                        "success": [k for k, v in result.get('p2p_status', {}).items() if v in ['PASSED', 'XFAIL']],
                        "failure": [k for k, v in result.get('p2p_status', {}).items() if v not in ['PASSED', 'XFAIL']]
                    },
                    "FAIL_TO_FAIL": {"success": [], "failure": []},
                    "PASS_TO_FAIL": {"success": [], "failure": []}
                }
            }
        }
        
        # Write report.json
        report_path = os.path.join(instance_dir, 'report.json')
        with open(report_path, 'w') as rf:
            json.dump(report, rf, indent=4)
        
        # Copy test output if exists
        test_output_src = os.path.join(eval_dir, 'test_outputs', f'{instance_id}.txt')
        if os.path.exists(test_output_src):
            import shutil
            shutil.copy(test_output_src, os.path.join(instance_dir, 'test_output.txt'))
        
        print(f"Created report for {instance_id}: resolved={result.get('resolved', False)}")

print("\nDone! Reports generated in OpenHands format.")
PYTHON_SCRIPT

export OUTPUT_DIR

echo ""
echo "=============================================="
echo "COMPLETE!"
echo "=============================================="
echo "Trajectory: $OUTPUT_DIR/output.jsonl"
echo "Eval Results: $OUTPUT_DIR/eval_outputs/"
echo ""
echo "Per-instance results in: $OUTPUT_DIR/eval_outputs/<instance_id>/report.json"
echo "=============================================="

