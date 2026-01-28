#!/bin/bash
# Remote worker script for batch evaluation

set -eo pipefail

MODEL_CONFIG="$1"
DATASET_DIR="$2"
MAX_ITER="$3"
EVAL_LIMIT="$4"
NUM_WORKERS="$5"
AGENT="$6"
VELORA_ROOT="$7"
HOST_ID="$8"
LOG_FILE="$9"

# Source shell profile to get poetry and other tools in PATH
# This is needed because SSH non-interactive sessions don't load .bashrc
if [ -f "$HOME/.bashrc" ]; then
  source "$HOME/.bashrc" 2>/dev/null || true
fi
if [ -f "$HOME/.profile" ]; then
  source "$HOME/.profile" 2>/dev/null || true
fi

# Add common poetry locations to PATH
export PATH="$HOME/.local/bin:$HOME/.poetry/bin:$PATH"

# Verify poetry is available
if ! command -v poetry &> /dev/null; then
  echo "ERROR: poetry not found on this host" | tee -a "$LOG_FILE"
  echo "Please install poetry: curl -sSL https://install.python-poetry.org | python3 -" | tee -a "$LOG_FILE"
  exit 1
fi

# Verify VeloraHarness directory exists
if [ ! -d "$VELORA_ROOT" ]; then
  echo "ERROR: VELORA_ROOT not found: $VELORA_ROOT" | tee -a "$LOG_FILE"
  exit 1
fi

# Verify the evaluation script exists
EVAL_SCRIPT="$VELORA_ROOT/evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh"
if [ ! -f "$EVAL_SCRIPT" ]; then
  echo "ERROR: Evaluation script not found: $EVAL_SCRIPT" | tee -a "$LOG_FILE"
  exit 1
fi

cd "$VELORA_ROOT"

# Find all .jsonl files in dataset directory
INSTANCES=($(find "$DATASET_DIR" -name "*.jsonl" -type f | sort))

echo "Worker $HOST_ID starting with ${#INSTANCES[@]} instances" | tee -a "$LOG_FILE"
echo "Poetry version: $(poetry --version 2>/dev/null || echo 'unknown')" | tee -a "$LOG_FILE"
echo "VELORA_ROOT: $VELORA_ROOT" | tee -a "$LOG_FILE"

COMPLETED=0
FAILED=0

for instance_file in "${INSTANCES[@]}"; do
  instance_id=$(cat "$instance_file" | python3 -c "import sys,json; print(json.load(sys.stdin).get('instance_id','unknown'))" 2>/dev/null || basename "$instance_file" .jsonl)

  echo "" | tee -a "$LOG_FILE"
  echo "========================================" | tee -a "$LOG_FILE"
  echo "Worker $HOST_ID: Starting $instance_id" | tee -a "$LOG_FILE"
  echo "========================================" | tee -a "$LOG_FILE"

  # Pre-run cleanup
  docker system prune -f --volumes 2>/dev/null || true

  # Run evaluation using absolute path
  START_TIME=$(date +%s)

  if bash "$EVAL_SCRIPT" \
      "$MODEL_CONFIG" "$instance_file" "$EVAL_LIMIT" "$MAX_ITER" "$NUM_WORKERS" "$AGENT" 2>&1 | tee -a "$LOG_FILE"; then
    COMPLETED=$((COMPLETED + 1))
    echo "Worker $HOST_ID: $instance_id COMPLETED" | tee -a "$LOG_FILE"
  else
    FAILED=$((FAILED + 1))
    echo "Worker $HOST_ID: $instance_id FAILED" | tee -a "$LOG_FILE"
  fi

  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))
  echo "Worker $HOST_ID: $instance_id took ${DURATION}s" | tee -a "$LOG_FILE"

  # Post-run cleanup
  docker system prune -f 2>/dev/null || true
done

echo "" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"
echo "Worker $HOST_ID FINISHED: $COMPLETED completed, $FAILED failed" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"
