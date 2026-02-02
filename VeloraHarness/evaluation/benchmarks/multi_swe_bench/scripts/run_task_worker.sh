#!/bin/bash
# run_task_worker.sh - Per-instance worker script for batch evaluation
#
# This script executes all trajectories for a single task:
#   - Runs each model x pass@N combination
#   - Handles errors and retries
#   - Updates status file for monitoring
#   - Cleans up Docker after completion
#
# Usage: ./run_task_worker.sh --dataset <path> --models <list> --pass-at-n <N> [OPTIONS]

set -eo pipefail

# ============================================
# CONFIGURATION
# ============================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VELORA_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# Default values
DATASET=""
MODELS=""
PASS_AT_N=8
MAX_ITERATIONS=1000
TIMEOUT=3600
RETRY_COUNT=1
RETRY_DELAY=300
OUTPUT_BASE=""
STATUS_FILE=""
MASTER_HOST=""
SSH_KEY=""
SSH_USER="ubuntu"
CLEANUP_AFTER_TASK=true
KEEP_BASE_IMAGES=true
DISK_THRESHOLD=85

# ============================================
# COLORS
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_header() { echo -e "\n${CYAN}============================================${NC}"; echo -e "${CYAN}$1${NC}"; echo -e "${CYAN}============================================${NC}"; }

# ============================================
# USAGE
# ============================================
usage() {
  cat << EOF
Usage: $0 [OPTIONS]

Required:
  --dataset PATH              Path to the dataset JSONL file
  --models LIST               Comma-separated list of model configs

Optional:
  --pass-at-n N               Number of trajectories per model (default: 8)
  --max-iterations N          Maximum agent iterations (default: 1000)
  --timeout SECONDS           Timeout per trajectory (default: 3600)
  --retry-count N             Number of retries for failures (default: 1)
  --output-base PATH          Base output directory
  --status-file PATH          Path to status JSON file
  --master-host HOST          Master host for output sync
  --ssh-key PATH              SSH key for master sync
  --no-cleanup                Disable Docker cleanup after task
  --help                      Show this help
EOF
  exit 1
}

# ============================================
# ARGUMENT PARSING
# ============================================
while [[ $# -gt 0 ]]; do
  case $1 in
    --dataset) DATASET="$2"; shift 2 ;;
    --models) MODELS="$2"; shift 2 ;;
    --pass-at-n) PASS_AT_N="$2"; shift 2 ;;
    --max-iterations) MAX_ITERATIONS="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --retry-count) RETRY_COUNT="$2"; shift 2 ;;
    --retry-delay) RETRY_DELAY="$2"; shift 2 ;;
    --output-base) OUTPUT_BASE="$2"; shift 2 ;;
    --status-file) STATUS_FILE="$2"; shift 2 ;;
    --master-host) MASTER_HOST="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --no-cleanup) CLEANUP_AFTER_TASK=false; shift ;;
    --help) usage ;;
    *) log_error "Unknown option: $1"; usage ;;
  esac
done

# ============================================
# VALIDATION
# ============================================
if [ -z "$DATASET" ]; then
  log_error "--dataset is required"
  usage
fi

if [ ! -f "$DATASET" ]; then
  log_error "Dataset file not found: $DATASET"
  exit 1
fi

if [ -z "$MODELS" ]; then
  log_error "--models is required"
  usage
fi

# Parse models into array
IFS=',' read -ra MODEL_ARRAY <<< "$MODELS"

# Extract task ID from dataset
TASK_ID=$(python3 -c "import json; print(json.load(open('$DATASET')).get('instance_id', 'unknown'))" 2>/dev/null)
if [ -z "$TASK_ID" ] || [ "$TASK_ID" = "unknown" ]; then
  TASK_ID=$(basename "$DATASET" .jsonl)
fi

# Set defaults
if [ -z "$OUTPUT_BASE" ]; then
  OUTPUT_BASE="${VELORA_ROOT}/evaluation/evaluation_outputs/batch_outputs"
fi

if [ -z "$STATUS_FILE" ]; then
  STATUS_FILE="/tmp/worker_status_${TASK_ID}.json"
fi

# ============================================
# STATUS FUNCTIONS
# ============================================
init_status() {
  python3 << PYEOF
import json
status = {
    "task_id": "$TASK_ID",
    "dataset": "$DATASET",
    "instance": "$(hostname)",
    "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "status": "running",
    "models": {},
    "errors": [],
    "last_updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
for model in "$MODELS".split(','):
    status['models'][model] = {
        'runs_completed': 0,
        'runs_total': $PASS_AT_N,
        'runs_failed': 0,
        'runs_success': 0,
        'current_run': 0,
        'status': 'pending'
    }
with open("$STATUS_FILE", 'w') as f:
    json.dump(status, f, indent=2)
PYEOF
}

update_status() {
  local model="$1"
  local field="$2"
  local value="$3"
  
  python3 << PYEOF
import json
with open("$STATUS_FILE", 'r') as f:
    status = json.load(f)
if '$model' in status['models']:
    status['models']['$model']['$field'] = $value
status['last_updated'] = "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
with open("$STATUS_FILE", 'w') as f:
    json.dump(status, f, indent=2)
PYEOF
}

update_global_status() {
  local new_status="$1"
  
  python3 << PYEOF
import json
with open("$STATUS_FILE", 'r') as f:
    status = json.load(f)
status['status'] = '$new_status'
status['last_updated'] = "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if '$new_status' == 'completed' or '$new_status' == 'completed_with_errors':
    status['completed_at'] = "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
with open("$STATUS_FILE", 'w') as f:
    json.dump(status, f, indent=2)
PYEOF
}

add_error() {
  local error_msg="$1"
  local model="$2"
  local run="$3"
  
  python3 << PYEOF
import json
with open("$STATUS_FILE", 'r') as f:
    status = json.load(f)
status['errors'].append({
    'timestamp': "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    'model': '$model',
    'run': $run,
    'message': """$error_msg"""
})
with open("$STATUS_FILE", 'w') as f:
    json.dump(status, f, indent=2)
PYEOF
}

# ============================================
# DOCKER CLEANUP FUNCTIONS
# ============================================
check_disk_usage() {
  df / | tail -1 | awk '{print $5}' | tr -d '%'
}

cleanup_docker_light() {
  log_info "Performing light Docker cleanup..."
  docker ps -q --filter 'name=openhands' 2>/dev/null | xargs -r docker stop 2>/dev/null || true
  docker ps -q --filter 'name=sweb' 2>/dev/null | xargs -r docker stop 2>/dev/null || true
  docker container prune -f 2>/dev/null || true
  docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | \
    grep -E '(ghcr.io/openhands/runtime|openhands-runtime)' | \
    xargs -r docker rmi -f 2>/dev/null || true
  docker image prune -f 2>/dev/null || true
  log_success "Light Docker cleanup complete"
}

cleanup_docker_aggressive() {
  log_warning "Performing aggressive Docker cleanup..."
  docker stop $(docker ps -q) 2>/dev/null || true
  docker container prune -f 2>/dev/null || true
  docker image prune -af 2>/dev/null || true
  docker volume prune -f 2>/dev/null || true
  docker builder prune -af 2>/dev/null || true
  log_success "Aggressive Docker cleanup complete"
}

cleanup_docker_for_task() {
  if [ "$CLEANUP_AFTER_TASK" = true ]; then
    log_info "Cleaning up Docker after task completion..."
    if [ "$KEEP_BASE_IMAGES" = true ]; then
      cleanup_docker_light
    else
      cleanup_docker_aggressive
    fi
    local usage=$(check_disk_usage)
    log_info "Disk usage after cleanup: ${usage}%"
  fi
}

ensure_disk_space() {
  local usage=$(check_disk_usage)
  if [ "$usage" -ge 95 ]; then
    log_error "Critical disk usage: ${usage}%"
    cleanup_docker_aggressive
    usage=$(check_disk_usage)
    if [ "$usage" -ge 90 ]; then
      log_error "Disk still critically full: ${usage}%"
      return 1
    fi
  elif [ "$usage" -ge "$DISK_THRESHOLD" ]; then
    log_warning "High disk usage: ${usage}%"
    cleanup_docker_light
  fi
  return 0
}

# ============================================
# OUTPUT SYNC FUNCTION
# ============================================
sync_to_master() {
  local source_dir="$1"
  if [ -z "$MASTER_HOST" ] || [ -z "$SSH_KEY" ]; then
    return 0
  fi
  log_info "Syncing outputs to master: $MASTER_HOST"
  local SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i $SSH_KEY"
  rsync -avz -e "ssh $SSH_OPTS" "$source_dir/" "${SSH_USER}@${MASTER_HOST}:${OUTPUT_BASE}/" 2>/dev/null || {
    log_warning "Failed to sync to master"
    return 1
  }
  log_success "Sync complete"
}

# ============================================
# RUN SINGLE TRAJECTORY
# ============================================
run_trajectory() {
  local model="$1"
  local run_num="$2"
  local retry_attempt="${3:-0}"
  
  log_info "Running trajectory: model=$model, run=$run_num, attempt=$((retry_attempt + 1))"
  
  if ! ensure_disk_space; then
    log_error "Cannot proceed due to disk space issues"
    return 1
  fi
  
  export N_RUNS=1
  local run_output_dir="${OUTPUT_BASE}/${TASK_ID}/${model}/run_${run_num}"
  mkdir -p "$run_output_dir"
  local log_file="${run_output_dir}/trajectory.log"
  local exit_code=0
  
  cd "$VELORA_ROOT"
  
  # Set RUN_ID environment variable for unique output
  export RUN_ID="$run_num"
  
  timeout "$TIMEOUT" bash evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_swe.sh \
    "$model" \
    "$DATASET" \
    1 \
    "$MAX_ITERATIONS" \
    1 \
    > "$log_file" 2>&1 || exit_code=$?
  
  if [ $exit_code -eq 0 ]; then
    if grep -q "SUCCESS: Full evaluation" "$log_file" 2>/dev/null; then
      log_success "Trajectory completed: model=$model, run=$run_num"
      local latest_output=$(find evaluation/evaluation_outputs/outputs -type f -name "output.jsonl" -mmin -30 2>/dev/null | head -1)
      if [ -n "$latest_output" ]; then
        cp -r "$(dirname "$latest_output")"/* "$run_output_dir/" 2>/dev/null || true
      fi
      return 0
    else
      log_warning "No success message found"
      exit_code=1
    fi
  elif [ $exit_code -eq 124 ]; then
    log_error "Trajectory timed out"
  else
    log_error "Trajectory failed with exit code: $exit_code"
  fi
  
  # Retry logic
  if [ $exit_code -ne 0 ] && [ "$retry_attempt" -lt "$RETRY_COUNT" ]; then
    if grep -q "no space left on device" "$log_file" 2>/dev/null; then
      cleanup_docker_aggressive
    elif grep -q "docker build" "$log_file" 2>/dev/null; then
      cleanup_docker_light
    fi
    log_info "Retrying trajectory..."
    sleep 30
    run_trajectory "$model" "$run_num" $((retry_attempt + 1))
    return $?
  fi
  
  return $exit_code
}

# ============================================
# MAIN EXECUTION
# ============================================
main() {
  log_header "WORKER: Starting Task Execution"
  echo "Task ID: $TASK_ID"
  echo "Dataset: $DATASET"
  echo "Models: ${MODEL_ARRAY[*]}"
  echo "Pass@N: $PASS_AT_N"
  echo "Max Iterations: $MAX_ITERATIONS"
  echo ""
  
  init_status
  mkdir -p "${OUTPUT_BASE}/${TASK_ID}"
  
  local total_runs=0
  local successful_runs=0
  local failed_runs=0
  
  for model in "${MODEL_ARRAY[@]}"; do
    log_header "Processing Model: $model"
    update_status "$model" "status" '"running"'
    
    local model_success=0
    local model_failed=0
    
    for run in $(seq 1 $PASS_AT_N); do
      log_info "Starting run $run/$PASS_AT_N for model $model"
      update_status "$model" "current_run" "$run"
      
      local run_output="${OUTPUT_BASE}/${TASK_ID}/${model}/run_${run}/output.jsonl"
      if [ -f "$run_output" ]; then
        log_info "Run $run already exists, skipping"
        model_success=$((model_success + 1))
        continue
      fi
      
      if run_trajectory "$model" "$run"; then
        model_success=$((model_success + 1))
        update_status "$model" "runs_success" "$model_success"
      else
        model_failed=$((model_failed + 1))
        update_status "$model" "runs_failed" "$model_failed"
        add_error "Trajectory failed" "$model" "$run"
      fi
      
      update_status "$model" "runs_completed" "$((model_success + model_failed))"
      total_runs=$((total_runs + 1))
    done
    
    if [ "$model_failed" -eq 0 ]; then
      update_status "$model" "status" '"completed"'
    else
      update_status "$model" "status" '"completed_with_errors"'
    fi
    
    successful_runs=$((successful_runs + model_success))
    failed_runs=$((failed_runs + model_failed))
    
    log_success "Model $model complete: $model_success success, $model_failed failed"
    cleanup_docker_light
    
    if [ -n "$MASTER_HOST" ]; then
      sync_to_master "${OUTPUT_BASE}/${TASK_ID}/${model}"
    fi
  done
  
  cleanup_docker_for_task
  
  if [ -n "$MASTER_HOST" ]; then
    sync_to_master "${OUTPUT_BASE}/${TASK_ID}"
  fi
  
  if [ "$failed_runs" -eq 0 ]; then
    update_global_status "completed"
  else
    update_global_status "completed_with_errors"
  fi
  
  log_header "TASK COMPLETE"
  echo "Task ID: $TASK_ID"
  echo "Total Runs: $total_runs"
  echo "Successful: $successful_runs"
  echo "Failed: $failed_runs"
  echo "Status file: $STATUS_FILE"
  echo "Outputs: ${OUTPUT_BASE}/${TASK_ID}/"
  
  if [ "$failed_runs" -gt 0 ]; then
    log_warning "Some runs failed - check status file for details"
    exit 1
  else
    log_success "All runs completed successfully!"
    exit 0
  fi
}

cd "$VELORA_ROOT"
main "$@"
