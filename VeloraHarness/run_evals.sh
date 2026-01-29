#!/bin/bash

export DOCKER_BUILDKIT=0
export EVAL_DOCKER_IMAGE_PREFIX="mswebench/"
export USE_INSTANCE_IMAGE=true
export LANGUAGE=python

cd /home/ubuntu/Velora_SWE_Harness/VeloraHarness/openhands

# Get poetry's site-packages path and prepend it to ensure external mcp is found first
SITE_PACKAGES=$(poetry run python -c "import site; print(site.getsitepackages()[0])")
export PYTHONPATH="${SITE_PACKAGES}:/home/ubuntu/Velora_SWE_Harness/VeloraHarness"

# Check if input file is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <path_to_output.jsonl>"
    echo ""
    echo "Example:"
    echo "  $0 /path/to/output.jsonl"
    echo ""
    echo "Recent output files:"
    find /home/ubuntu/Velora_SWE_Harness/VeloraHarness -name "output.jsonl" -type f -mtime -7 2>/dev/null | head -10
    exit 1
fi

INPUT_FILE="$1"

if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: Input file not found: $INPUT_FILE"
    exit 1
fi

echo "Running evaluation on: $INPUT_FILE"

poetry run python /home/ubuntu/Velora_SWE_Harness/VeloraHarness/evaluation/benchmarks/multi_swe_bench/eval_infer.py \
    --input-file "$INPUT_FILE" \
    --dataset /home/ubuntu/Velora_SWE_Harness/VeloraHarness/data/datasets/conan-io__conan_2.0.14_2.0.15.jsonl \
    --split train \
    --eval-num-workers 1
