#!/bin/bash
# run_full_eval_fixed.sh - Complete Velora evaluation pipeline with detailed reports
#
# This script runs BOTH:
#   1. Trajectory generation (run_infer.py) - Generates git patches
#   2. Patch evaluation (eval_pilot2_standardized.py) - Full detailed evaluation
#
# Output structure (matches OpenHands default):
#   evaluation_outputs/outputs/.../
#   ├── output.jsonl              ← Trajectory + git_patch
#   ├── metadata.json             ← Run metadata
#   ├── llm_completions/          ← LLM responses
#   └── eval_outputs/             ← Evaluation results
#       ├── report.json           ← Aggregate report
#       └── <instance_id>/
#           ├── report.json       ← Detailed test breakdown (OpenHands format)
#           ├── patch.diff        ← Applied patch
#           ├── test_output.txt   ← Full test output
#           └── run_instance.log  ← Execution log
#
# Usage: ./run_full_eval_fixed.sh MODEL_CONFIG DATASET [EVAL_LIMIT] [MAX_ITER] [NUM_WORKERS]
# Example: ./run_full_eval_fixed.sh llm.gpt data/task.jsonl 1 200 1

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
echo "VELORA FULL EVALUATION PIPELINE (FIXED)"
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
# EXTRACT INSTANCE ID
# ============================================
INSTANCE_ID=$(cat "$OUTPUT_FILE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('instance_id', ''))
" 2>/dev/null)

if [ -z "$INSTANCE_ID" ]; then
  echo "ERROR: Could not extract instance_id from output.jsonl"
  exit 1
fi

echo "Instance ID: $INSTANCE_ID"

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
SCRIPT_DIR=$(dirname "$0")
EVAL_OUTPUT_FILE="${OUTPUT_DIR}/eval_pilot2_output.jsonl"

# Determine Docker image name
DOCKER_IMAGE="mswebench/sweb.eval.x86_64.${INSTANCE_ID}:latest"
echo "Docker image: $DOCKER_IMAGE"

EVAL_COMMAND="python3 $SCRIPT_DIR/eval_pilot2_standardized.py \
  --trajectory-file $OUTPUT_FILE \
  --dataset-file $DATASET_ABS \
  --docker-image $DOCKER_IMAGE \
  --output-file $EVAL_OUTPUT_FILE \
  --timeout 600"

echo "Running: $EVAL_COMMAND"
echo ""
eval $EVAL_COMMAND

EVAL_EXIT=$?

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

python3 << 'PYEOF'
import json
import os
import sys

# Load eval_pilot2 output
eval_output_file = os.environ['EVAL_OUTPUT_FILE']
output_dir = os.environ['OUTPUT_DIR']
instance_id = os.environ['INSTANCE_ID']

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
print(f"F2P Success: {len(details.get('fail_to_pass_success', []))}/{len(details.get('fail_to_pass_success', []))+len(details.get('fail_to_pass_failed', []))}")
print(f"P2P Success: {len(details.get('pass_to_pass_success', []))}/{len(details.get('pass_to_pass_success', []))+len(details.get('pass_to_pass_failed', []))}")
print("=" * 60)

PYEOF

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
echo "SUCCESS: Full evaluation with detailed reports complete"
echo "============================================"

