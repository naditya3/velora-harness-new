#!/bin/bash
# run_all_trajectories.sh - Generate trajectories for all models and tasks
#
# This script generates trajectories for:
# - 3 models: gpt-5.2-codex, gemini-3-pro-preview, claude-opus-4-5-20251101
# - 2 tasks: 12155_1, 13066_1
# - 1000 iterations each
#
# Total: 6 trajectory generations

set -eo pipefail

# ============================================
# CONFIGURATION
# ============================================
export DOCKER_BUILDKIT=0
export EVAL_DOCKER_IMAGE_PREFIX="mswebench"
export USE_INSTANCE_IMAGE=true
export LANGUAGE=javascript   # Expensify tasks are JavaScript
export RUN_WITH_BROWSING=false
export USE_HINT_TEXT=false
export PYTHONPATH="$(pwd):$PYTHONPATH"

# Models to run
MODELS=("llm.gpt" "llm.gemini3" "llm.claude")
MODEL_NAMES=("gpt-5.2-codex" "gemini-3-pro-preview" "claude-opus-4-5-20251101")

# Tasks (dataset files)
TASKS=("12155_1" "13066_1")

# Evaluation parameters
MAX_ITER=1000
EVAL_LIMIT=1
NUM_WORKERS=1
AGENT="CodeActAgent"
SPLIT="train"

# Output directories and log files
LOG_DIR="trajectory_logs_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"

SUMMARY_FILE="$LOG_DIR/summary_report.md"
ISSUES_FILE="$LOG_DIR/issues_encountered.txt"

# Initialize files
echo "# Trajectory Generation Summary Report" > "$SUMMARY_FILE"
echo "Generated: $(date)" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"
echo "## Configuration" >> "$SUMMARY_FILE"
echo "- Max Iterations: $MAX_ITER" >> "$SUMMARY_FILE"
echo "- Models: ${MODEL_NAMES[*]}" >> "$SUMMARY_FILE"
echo "- Tasks: ${TASKS[*]}" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"

echo "# Issues Encountered During Trajectory Generation" > "$ISSUES_FILE"
echo "Generated: $(date)" >> "$ISSUES_FILE"
echo "" >> "$ISSUES_FILE"

# ============================================
# FUNCTIONS
# ============================================
log_issue() {
    local model=$1
    local task=$2
    local issue=$3
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Model: $model, Task: $task - $issue" >> "$ISSUES_FILE"
}

check_error_field() {
    local output_file=$1
    local error_value=$(python3 -c "
import json
import sys
try:
    with open('$output_file', 'r') as f:
        d = json.load(f)
    error = d.get('error', None)
    if error is None or error == '' or error == 'null':
        print('NULL_OR_EMPTY')
    else:
        print(error)
except Exception as e:
    print(f'ERROR_READING: {e}')
" 2>/dev/null)
    echo "$error_value"
}

# ============================================
# PRE-RUN CLEANUP
# ============================================
echo "============================================"
echo "PRE-RUN CLEANUP"
echo "============================================"

# Clean up old runtime images to free disk space
echo "Cleaning up old Docker images..."
docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -E "ghcr.io/openhands/runtime" | head -20 | xargs -r docker rmi -f 2>/dev/null || true
docker container prune -f 2>/dev/null || true
docker image prune -f 2>/dev/null || true

echo "✓ Pre-run cleanup complete"
echo ""

# ============================================
# TRAJECTORY GENERATION
# ============================================
echo "============================================"
echo "STARTING TRAJECTORY GENERATION"
echo "============================================"
echo ""

TOTAL_RUNS=$((${#MODELS[@]} * ${#TASKS[@]}))
CURRENT_RUN=0
SUCCESSFUL_RUNS=0
FAILED_RUNS=0

# Track results
declare -A RESULTS

for i in "${!MODELS[@]}"; do
    MODEL="${MODELS[$i]}"
    MODEL_NAME="${MODEL_NAMES[$i]}"

    for TASK in "${TASKS[@]}"; do
        CURRENT_RUN=$((CURRENT_RUN + 1))
        DATASET_FILE="$(pwd)/dataset/${TASK}.jsonl"
        LOG_FILE="$LOG_DIR/${MODEL_NAME}_${TASK}.log"

        echo "============================================"
        echo "[$CURRENT_RUN/$TOTAL_RUNS] Running: $MODEL_NAME on task $TASK"
        echo "============================================"
        echo "Dataset: $DATASET_FILE"
        echo "Log: $LOG_FILE"
        echo ""

        # Verify dataset exists
        if [ ! -f "$DATASET_FILE" ]; then
            echo "ERROR: Dataset file not found: $DATASET_FILE"
            log_issue "$MODEL_NAME" "$TASK" "Dataset file not found"
            FAILED_RUNS=$((FAILED_RUNS + 1))
            RESULTS["${MODEL_NAME}_${TASK}"]="FAILED: Dataset not found"
            continue
        fi

        # Build evaluation note
        EVAL_NOTE="v1.1.0-no-hint-${MODEL_NAME}-${TASK}-run_1"

        # Run trajectory generation
        INFER_COMMAND="poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
            --agent-cls $AGENT \
            --llm-config $MODEL \
            --max-iterations $MAX_ITER \
            --eval-num-workers $NUM_WORKERS \
            --eval-note $EVAL_NOTE \
            --dataset $DATASET_FILE \
            --split $SPLIT \
            --eval-n-limit $EVAL_LIMIT"

        echo "Command: $INFER_COMMAND"
        echo ""

        # Run and capture output
        START_TIME=$(date +%s)

        if eval $INFER_COMMAND 2>&1 | tee "$LOG_FILE"; then
            END_TIME=$(date +%s)
            DURATION=$((END_TIME - START_TIME))
            echo ""
            echo "✓ Completed in ${DURATION}s"

            # Find the output file
            OUTPUT_BASE="evaluation/evaluation_outputs/outputs"
            OUTPUT_FILE=$(find $OUTPUT_BASE -type f -name "output.jsonl" 2>/dev/null | grep "${TASK}" | grep -E "${EVAL_NOTE}|maxiter_${MAX_ITER}" | head -1)

            if [ -z "$OUTPUT_FILE" ]; then
                OUTPUT_FILE=$(find $OUTPUT_BASE -type f -name "output.jsonl" -newer "$LOG_FILE" 2>/dev/null | head -1)
            fi

            if [ -n "$OUTPUT_FILE" ] && [ -f "$OUTPUT_FILE" ]; then
                echo "Output file: $OUTPUT_FILE"

                # Check error field
                ERROR_VALUE=$(check_error_field "$OUTPUT_FILE")

                if [ "$ERROR_VALUE" = "NULL_OR_EMPTY" ]; then
                    echo "✓ Error field is null/empty (success)"
                    SUCCESSFUL_RUNS=$((SUCCESSFUL_RUNS + 1))
                    RESULTS["${MODEL_NAME}_${TASK}"]="SUCCESS (${DURATION}s)"
                else
                    echo "WARNING: Error field has value: $ERROR_VALUE"
                    log_issue "$MODEL_NAME" "$TASK" "Error field has value: $ERROR_VALUE"
                    SUCCESSFUL_RUNS=$((SUCCESSFUL_RUNS + 1))  # Still count as successful run
                    RESULTS["${MODEL_NAME}_${TASK}"]="SUCCESS with error: $ERROR_VALUE (${DURATION}s)"
                fi
            else
                echo "WARNING: Output file not found"
                log_issue "$MODEL_NAME" "$TASK" "Output file not found after completion"
                FAILED_RUNS=$((FAILED_RUNS + 1))
                RESULTS["${MODEL_NAME}_${TASK}"]="FAILED: Output not found"
            fi
        else
            END_TIME=$(date +%s)
            DURATION=$((END_TIME - START_TIME))
            echo ""
            echo "✗ Failed after ${DURATION}s"
            log_issue "$MODEL_NAME" "$TASK" "Run failed after ${DURATION}s"
            FAILED_RUNS=$((FAILED_RUNS + 1))
            RESULTS["${MODEL_NAME}_${TASK}"]="FAILED (${DURATION}s)"
        fi

        echo ""

        # Clean up between runs to prevent disk space issues
        echo "Cleaning up between runs..."
        docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -E "ghcr.io/openhands/runtime" | head -10 | xargs -r docker rmi -f 2>/dev/null || true
        docker container prune -f 2>/dev/null || true
        echo ""
    done
done

# ============================================
# GENERATE SUMMARY REPORT
# ============================================
echo "" >> "$SUMMARY_FILE"
echo "## Results" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"
echo "| Model | Task | Status |" >> "$SUMMARY_FILE"
echo "|-------|------|--------|" >> "$SUMMARY_FILE"

for i in "${!MODELS[@]}"; do
    MODEL_NAME="${MODEL_NAMES[$i]}"
    for TASK in "${TASKS[@]}"; do
        STATUS="${RESULTS[${MODEL_NAME}_${TASK}]}"
        echo "| $MODEL_NAME | $TASK | $STATUS |" >> "$SUMMARY_FILE"
    done
done

echo "" >> "$SUMMARY_FILE"
echo "## Summary" >> "$SUMMARY_FILE"
echo "- Total runs: $TOTAL_RUNS" >> "$SUMMARY_FILE"
echo "- Successful: $SUCCESSFUL_RUNS" >> "$SUMMARY_FILE"
echo "- Failed: $FAILED_RUNS" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"

# ============================================
# FINAL OUTPUT
# ============================================
echo "============================================"
echo "TRAJECTORY GENERATION COMPLETE"
echo "============================================"
echo ""
echo "Summary:"
echo "  Total runs: $TOTAL_RUNS"
echo "  Successful: $SUCCESSFUL_RUNS"
echo "  Failed: $FAILED_RUNS"
echo ""
echo "Results:"
for i in "${!MODELS[@]}"; do
    MODEL_NAME="${MODEL_NAMES[$i]}"
    for TASK in "${TASKS[@]}"; do
        STATUS="${RESULTS[${MODEL_NAME}_${TASK}]}"
        echo "  $MODEL_NAME + $TASK: $STATUS"
    done
done
echo ""
echo "Log files: $LOG_DIR/"
echo "Summary report: $SUMMARY_FILE"
echo "Issues file: $ISSUES_FILE"
echo ""
