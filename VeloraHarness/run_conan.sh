#!/bin/bash

export DOCKER_BUILDKIT=0
export EVAL_DOCKER_IMAGE_PREFIX="mswebench/"
export USE_INSTANCE_IMAGE=true
export LANGUAGE=python
export RUN_WITH_BROWSING=false

cd /home/ubuntu/Velora_SWE_Harness/VeloraHarness/openhands

# Get poetry's site-packages path and prepend it to ensure external mcp is found first
SITE_PACKAGES=$(poetry run python -c "import site; print(site.getsitepackages()[0])")
export PYTHONPATH="${SITE_PACKAGES}:/home/ubuntu/Velora_SWE_Harness/VeloraHarness"

poetry run python /home/ubuntu/Velora_SWE_Harness/VeloraHarness/evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent-cls CodeActAgent \
    --llm-config llm.gpt \
    --max-iterations 900 \
    --eval-num-workers 1 \
    --eval-n-limit 1 \
    --dataset /home/ubuntu/Velora_SWE_Harness/VeloraHarness/data/datasets/sumit.jsonl \
    --split train \
    --eval-note conan_modified_without_browsing
