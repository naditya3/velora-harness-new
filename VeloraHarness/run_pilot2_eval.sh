#!/bin/bash

# Pilot 2.2 Standardized Evaluation Script
# Usage: ./run_pilot2_eval.sh <trajectory_file> <dataset_file> <docker_image> [output_file] [timeout]

export DOCKER_BUILDKIT=0

cd /home/ubuntu/Velora_SWE_Harness/VeloraHarness

# Get poetry's site-packages path
SITE_PACKAGES=$(cd openhands && poetry run python -c "import site; print(site.getsitepackages()[0])")
export PYTHONPATH="${SITE_PACKAGES}:/home/ubuntu/Velora_SWE_Harness/VeloraHarness"

# Check arguments
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    echo "Usage: $0 <trajectory_file> <dataset_file> <docker_image> [output_file] [timeout]"
    echo ""
    echo "Required arguments:"
    echo "  trajectory_file  - Path to trajectory output.jsonl (model's solution)"
    echo "  dataset_file     - Path to dataset JSONL (task definition with F2P/P2P tests)"
    echo "  docker_image     - Docker image name or path to .tar file"
    echo ""
    echo "Optional arguments:"
    echo "  output_file      - Output file for eval results (default: eval_output.jsonl)"
    echo "  timeout          - Test timeout in seconds (default: 900)"
    echo ""
    echo "Examples:"
    echo "  $0 /path/to/output.jsonl /path/to/task.jsonl mswebench/sweb.eval.x86_64.task:latest"
    echo "  $0 output.jsonl task.jsonl my_image:tag result.jsonl 1200"
    echo ""
    echo "Recent trajectory files:"
    find /home/ubuntu/Velora_SWE_Harness/VeloraHarness -name "output.jsonl" -type f -mtime -7 2>/dev/null | head -10
    exit 1
fi

TRAJECTORY_FILE="$1"
DATASET_FILE="$2"
DOCKER_IMAGE="$3"
OUTPUT_FILE="${4:-eval_output.jsonl}"
TIMEOUT="${5:-900}"

# Validate files exist
if [ ! -f "$TRAJECTORY_FILE" ]; then
    echo "Error: Trajectory file not found: $TRAJECTORY_FILE"
    exit 1
fi

if [ ! -f "$DATASET_FILE" ]; then
    echo "Error: Dataset file not found: $DATASET_FILE"
    exit 1
fi

echo "========================================"
echo "Pilot 2.2 Standardized Evaluation"
echo "========================================"
echo "Trajectory:   $TRAJECTORY_FILE"
echo "Dataset:      $DATASET_FILE"
echo "Docker Image: $DOCKER_IMAGE"
echo "Output:       $OUTPUT_FILE"
echo "Timeout:      ${TIMEOUT}s"
echo "========================================"

cd openhands && poetry run python \
    /home/ubuntu/Velora_SWE_Harness/VeloraHarness/evaluation/benchmarks/multi_swe_bench/scripts/eval_pilot2_standardized.py \
    --trajectory-file "$TRAJECTORY_FILE" \
    --dataset-file "$DATASET_FILE" \
    --docker-image "$DOCKER_IMAGE" \
    --output-file "$OUTPUT_FILE" \
    --timeout "$TIMEOUT"

EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo "✓ Evaluation PASSED (resolved=true)"
else
    echo "✗ Evaluation FAILED (resolved=false or error)"
fi

echo "Results saved to: $OUTPUT_FILE"
exit $EXIT_CODE
