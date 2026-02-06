#!/usr/bin/env bash
################################################################################
# Quick Single Instance Test Script
# Usage: ./test_single.sh <instance_id> [model]
################################################################################

set -eo pipefail

INSTANCE_ID="${1:-576003528906636}"  # Default to Python/mypy instance
MODEL="${2:-opus}"                    # Default to Claude Opus

PROJECT_ROOT="/home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness"
DATASET_PATH="${PROJECT_ROOT}/data/repomate_75_samples.jsonl"
TEST_DIR="${PROJECT_ROOT}/data/test"
OUTPUT_DIR="/home/ec2-user/VeloraTrajectories/outputs/test_single"

mkdir -p "${TEST_DIR}" "${OUTPUT_DIR}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "================================================================================"
echo "  Testing Single Instance: ${INSTANCE_ID}"
echo "  Model: ${MODEL}"
echo "================================================================================"
echo

# Check if instance exists in dataset
if ! jq -e "select(.instance_id == \"${INSTANCE_ID}\")" "${DATASET_PATH}" > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Instance ${INSTANCE_ID} not found in dataset${NC}"
    exit 1
fi

# Show instance details
echo -e "${BLUE}Instance Details:${NC}"
jq -c "select(.instance_id == \"${INSTANCE_ID}\") | {instance_id, repo, language, pr_title}" "${DATASET_PATH}"
echo

# Create single-instance dataset
TEST_DATASET="${TEST_DIR}/test_${INSTANCE_ID}.jsonl"
jq -c "select(.instance_id == \"${INSTANCE_ID}\")" "${DATASET_PATH}" > "${TEST_DATASET}"

echo -e "${BLUE}Created test dataset: ${TEST_DATASET}${NC}"
echo

# Run inference
cd "${PROJECT_ROOT}"
export PYTHONPATH="${PROJECT_ROOT}:${PYTHONPATH}"
export USE_INSTANCE_IMAGE=false

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${OUTPUT_DIR}/test_${INSTANCE_ID}_${MODEL}_${TIMESTAMP}.log"

echo -e "${BLUE}Starting trajectory generation...${NC}"
echo -e "${BLUE}Log file: ${LOG_FILE}${NC}"
echo

sg docker -c "python3 ${PROJECT_ROOT}/evaluation/benchmarks/swe_bench/run_infer.py \
    --agent-cls CodeActAgent \
    --llm-config ${MODEL} \
    --max-iterations 500 \
    --eval-num-workers 1 \
    --dataset ${TEST_DATASET} \
    --split train \
    --eval-note test_single_${INSTANCE_ID}_${MODEL} \
    2>&1 | tee ${LOG_FILE}"

EXIT_CODE=$?

echo
echo "================================================================================"
if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✓ Test completed successfully!${NC}"
else
    echo -e "${RED}✗ Test failed with exit code: ${EXIT_CODE}${NC}"
fi
echo "================================================================================"
echo
echo "Log file: ${LOG_FILE}"
echo "Output directory: ${OUTPUT_DIR}"
echo

exit $EXIT_CODE
