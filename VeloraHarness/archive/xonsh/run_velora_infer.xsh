#!/usr/bin/env xonsh
# run_velora_infer.xsh - Modified run_infer for Velora 200 tasks
# Usage: ./run_velora_infer.xsh MODEL_CONFIG DATASET [EVAL_LIMIT] [MAX_ITER] [NUM_WORKERS]
# Example: ./run_velora_infer.xsh llm.gpt ~/datasets/task.jsonl 1 200 1

import sys
from pathlib import Path

# ============================================
# VELORA-SPECIFIC ENVIRONMENT VARIABLES
# ============================================
$DOCKER_BUILDKIT = "0"                    # CRITICAL: Prevents buildx failures
$EVAL_DOCKER_IMAGE_PREFIX = "mswebench/"  # Our Docker image prefix
$USE_INSTANCE_IMAGE = "true"              # Use instance-specific images
$LANGUAGE = "python"                      # Our tasks are Python
$RUN_WITH_BROWSING = "false"
$USE_HINT_TEXT = "false"

# ============================================
# ARGUMENT PARSING
# ============================================
def parse_args():
    args = sys.argv[1:]
    if len(args) < 2:
        print("ERROR: MODEL_CONFIG and DATASET are required")
        print("Usage: run_velora_infer.xsh MODEL_CONFIG DATASET [EVAL_LIMIT] [MAX_ITER] [NUM_WORKERS] [AGENT]")
        sys.exit(1)
    
    model_config = args[0]
    dataset = args[1]
    eval_limit = args[2] if len(args) > 2 else "1"
    max_iter = args[3] if len(args) > 3 else "200"
    num_workers = args[4] if len(args) > 4 else "1"
    agent = args[5] if len(args) > 5 else "CodeActAgent"
    split = "train"
    
    return model_config, dataset, eval_limit, max_iter, num_workers, agent, split

model_config, dataset, eval_limit, max_iter, num_workers, agent, split = parse_args()

# ============================================
# VALIDATION
# ============================================
dataset_path = Path(dataset)
if not dataset_path.exists():
    print(f"ERROR: Dataset file not found: {dataset}")
    sys.exit(1)

# ============================================
# DISPLAY CONFIGURATION
# ============================================
print("=" * 44)
print("VELORA TRAJECTORY GENERATION")
print("=" * 44)
print(f"MODEL_CONFIG: {model_config}")
print(f"DATASET: {dataset}")
print(f"EVAL_LIMIT: {eval_limit}")
print(f"MAX_ITER: {max_iter}")
print(f"NUM_WORKERS: {num_workers}")
print(f"AGENT: {agent}")
print(f"SPLIT: {split}")
print()
print("Environment:")
print(f"  DOCKER_BUILDKIT: {$DOCKER_BUILDKIT}")
print(f"  EVAL_DOCKER_IMAGE_PREFIX: {$EVAL_DOCKER_IMAGE_PREFIX}")
print(f"  USE_INSTANCE_IMAGE: {$USE_INSTANCE_IMAGE}")
print(f"  LANGUAGE: {$LANGUAGE}")
print("=" * 44)

# ============================================
# GET OPENHANDS VERSION
# ============================================
openhands_version = "v1.1.0"
print(f"OPENHANDS_VERSION: {openhands_version}")

# ============================================
# BUILD EVAL NOTE
# ============================================
eval_note = f"{openhands_version}-no-hint"
if 'EXP_NAME' in ${...}:
    eval_note = f"{eval_note}-{$EXP_NAME}"

# ============================================
# RUN INFERENCE
# ============================================
if 'SANDBOX_ENV_GITHUB_TOKEN' in ${...}:
    del $SANDBOX_ENV_GITHUB_TOKEN  # Prevent agent from using github token

n_runs = int(${...}.get('N_RUNS', '1'))
for i in range(1, n_runs + 1):
    current_eval_note = f"{eval_note}-run_{i}"
    print()
    print(f"Starting run {i} with eval_note: {current_eval_note}")
    print()
    
    poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
        --agent-cls @(agent) \
        --llm-config @(model_config) \
        --max-iterations @(max_iter) \
        --eval-num-workers @(num_workers) \
        --eval-note @(current_eval_note) \
        --dataset @(dataset) \
        --split @(split) \
        --eval-n-limit @(eval_limit)

print()
print("=" * 44)
print("TRAJECTORY GENERATION COMPLETE")
print("=" * 44)
