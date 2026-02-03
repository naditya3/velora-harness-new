#!/bin/bash
# run_batch_master.sh - Master orchestration script for batch evaluation
#
# This script:
#   - Parses batch configuration
#   - Discovers datasets from directory
#   - Assigns tasks to worker instances (one full task per instance)
#   - Launches remote workers via SSH
#   - Monitors progress and handles retries
#   - Syncs outputs to master instance
#   - Generates final summary report
#
# Usage: ./run_batch_master.sh --config batch_config.toml [OPTIONS]
#
# Example:
#   ./run_batch_master.sh --config batch_config.toml
#   nohup ./run_batch_master.sh --config batch_config.toml > batch.log 2>&1 &

set -eo pipefail

# ============================================
# CONFIGURATION
# ============================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VELORA_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# Default values
CONFIG_FILE=""
DRY_RUN=false
VERBOSE=false
LOCAL_ONLY=false

# Config values (loaded from TOML)
PASS_AT_N=8
MAX_ITERATIONS=1000
TIMEOUT=3600
RETRY_COUNT=1
MODELS=()
WORKERS=()
MASTER_HOST=""
SSH_KEY=""
SSH_USER="ubuntu"
SSH_PORT=22
REMOTE_VELORA_PATH=""
DATASET_DIR=""
DATASET_FILES=()
OUTPUT_BASE=""
STATUS_FILE="/tmp/batch_status.json"
LOG_FILE="/tmp/batch_master.log"
STATUS_INTERVAL=60

# ============================================
# COLORS
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"; }
log_header() { 
  echo -e "\n${CYAN}============================================${NC}" | tee -a "$LOG_FILE"
  echo -e "${CYAN}$1${NC}" | tee -a "$LOG_FILE"
  echo -e "${CYAN}============================================${NC}" | tee -a "$LOG_FILE"
}

# ============================================
# USAGE
# ============================================
usage() {
  cat << EOF
Usage: $0 [OPTIONS]

Required:
  --config PATH               Path to batch configuration TOML file

Optional:
  --dry-run                   Show what would be done without executing
  --local-only                Run all tasks on local machine (no SSH)
  --verbose                   Enable verbose output
  --help                      Show this help

Examples:
  # Run with config file
  $0 --config batch_config.toml

  # Dry run to see task distribution
  $0 --config batch_config.toml --dry-run

  # Run locally without remote workers
  $0 --config batch_config.toml --local-only
EOF
  exit 1
}

# ============================================
# ARGUMENT PARSING
# ============================================
while [[ $# -gt 0 ]]; do
  case $1 in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --local-only) LOCAL_ONLY=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --help) usage ;;
    *) log_error "Unknown option: $1"; usage ;;
  esac
done

# ============================================
# VALIDATION
# ============================================
if [ -z "$CONFIG_FILE" ]; then
  log_error "--config is required"
  usage
fi

if [ ! -f "$CONFIG_FILE" ]; then
  log_error "Config file not found: $CONFIG_FILE"
  exit 1
fi

# ============================================
# PARSE TOML CONFIG
# ============================================
parse_config() {
  log_info "Parsing configuration: $CONFIG_FILE"
  
  # Use Python to parse TOML
  eval $(python3 << PYEOF
import re

def parse_toml_simple(filepath):
    """Simple TOML parser for our config format."""
    config = {}
    current_section = None
    
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            
            # Skip empty lines and comments
            if not line or line.startswith('#'):
                continue
            
            # Section header
            if line.startswith('[') and line.endswith(']'):
                current_section = line[1:-1]
                if current_section not in config:
                    config[current_section] = {}
                continue
            
            # Key-value pair
            if '=' in line and current_section:
                key, value = line.split('=', 1)
                key = key.strip()
                value = value.strip()
                
                # Remove inline comments
                if '#' in value and not value.startswith('"') and not value.startswith('['):
                    value = value.split('#')[0].strip()
                
                # Parse value
                if value.startswith('"') and value.endswith('"'):
                    value = value[1:-1]
                elif value.startswith('[') and value.endswith(']'):
                    # Array
                    items = value[1:-1].split(',')
                    value = [item.strip().strip('"') for item in items if item.strip()]
                elif value == 'true':
                    value = True
                elif value == 'false':
                    value = False
                elif value.isdigit():
                    value = int(value)
                
                config[current_section][key] = value
    
    return config

config = parse_toml_simple("$CONFIG_FILE")

# Output bash variables
batch = config.get('batch', {})
print(f"PASS_AT_N={batch.get('pass_at_n', 8)}")
print(f"MAX_ITERATIONS={batch.get('max_iterations', 1000)}")
print(f"TIMEOUT={batch.get('timeout_per_trajectory', 3600)}")
print(f"RETRY_COUNT={batch.get('retry_count', 1)}")

models = config.get('models', {})
enabled = models.get('enabled', [])
if isinstance(enabled, list):
    print(f"MODELS_STR='{','.join(enabled)}'")
else:
    print(f"MODELS_STR='{enabled}'")

instances = config.get('instances', {})
print(f"MASTER_HOST='{instances.get('master', '')}'")
workers = instances.get('workers', [])
if isinstance(workers, list):
    print(f"WORKERS_STR='{','.join(workers)}'")
else:
    print(f"WORKERS_STR='{workers}'")
print(f"SSH_KEY='{instances.get('ssh_key', '~/.ssh/velora.pem')}'")
print(f"SSH_USER='{instances.get('ssh_user', 'ubuntu')}'")
print(f"SSH_PORT={instances.get('ssh_port', 22)}")
print(f"REMOTE_VELORA_PATH='{instances.get('remote_velora_path', '/home/ubuntu/Velora_SWE_Harness/VeloraHarness')}'")

datasets = config.get('datasets', {})
print(f"DATASET_DIR='{datasets.get('directory', 'data/')}'")
files = datasets.get('files', [])
if isinstance(files, list) and files:
    print(f"DATASET_FILES_STR='{','.join(files)}'")
else:
    print("DATASET_FILES_STR=''")

output = config.get('output', {})
print(f"OUTPUT_BASE='{output.get('base_dir', 'evaluation/evaluation_outputs/batch_outputs')}'")

monitoring = config.get('monitoring', {})
print(f"STATUS_INTERVAL={monitoring.get('status_interval', 60)}")
print(f"LOG_FILE='{monitoring.get('log_file', '/tmp/batch_master.log')}'")
print(f"STATUS_FILE='{monitoring.get('status_file', '/tmp/batch_status.json')}'")
PYEOF
)

  # Parse models and workers into arrays
  IFS=',' read -ra MODELS <<< "$MODELS_STR"
  IFS=',' read -ra WORKERS <<< "$WORKERS_STR"
  
  # Parse dataset files if specified
  if [ -n "$DATASET_FILES_STR" ]; then
    IFS=',' read -ra DATASET_FILES <<< "$DATASET_FILES_STR"
  fi
  
  # Expand SSH key path
  SSH_KEY="${SSH_KEY/#\~/$HOME}"
}

# ============================================
# DISCOVER DATASETS
# ============================================
discover_datasets() {
  log_info "Discovering datasets..."
  
  if [ ${#DATASET_FILES[@]} -gt 0 ]; then
    log_info "Using explicit dataset list: ${#DATASET_FILES[@]} files"
    return
  fi
  
  # Find all JSONL files in the dataset directory
  local dataset_path="${VELORA_ROOT}/${DATASET_DIR}"
  if [ ! -d "$dataset_path" ]; then
    log_error "Dataset directory not found: $dataset_path"
    exit 1
  fi
  
  while IFS= read -r -d '' file; do
    DATASET_FILES+=("$file")
  done < <(find "$dataset_path" -maxdepth 1 -name "*.jsonl" -type f -print0 | sort -z)
  
  if [ ${#DATASET_FILES[@]} -eq 0 ]; then
    log_error "No JSONL files found in: $dataset_path"
    exit 1
  fi
  
  log_info "Found ${#DATASET_FILES[@]} dataset files"
}

# ============================================
# SSH FUNCTIONS
# ============================================
SSH_OPTS=""

setup_ssh() {
  SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -i $SSH_KEY -p $SSH_PORT"
}

run_remote() {
  local host="$1"
  local cmd="$2"
  ssh $SSH_OPTS "${SSH_USER}@${host}" "$cmd"
}

check_host() {
  local host="$1"
  ssh $SSH_OPTS "${SSH_USER}@${host}" "echo 'OK'" 2>/dev/null
}

# ============================================
# STATUS FUNCTIONS
# ============================================
init_master_status() {
  python3 << PYEOF
import json
from datetime import datetime

status = {
    "started_at": datetime.utcnow().isoformat() + "Z",
    "status": "running",
    "config_file": "$CONFIG_FILE",
    "total_tasks": ${#DATASET_FILES[@]},
    "total_models": ${#MODELS[@]},
    "pass_at_n": $PASS_AT_N,
    "total_trajectories": ${#DATASET_FILES[@]} * ${#MODELS[@]} * $PASS_AT_N,
    "tasks": {},
    "workers": {},
    "summary": {
        "tasks_completed": 0,
        "tasks_failed": 0,
        "trajectories_completed": 0,
        "trajectories_failed": 0
    },
    "last_updated": datetime.utcnow().isoformat() + "Z"
}

with open("$STATUS_FILE", 'w') as f:
    json.dump(status, f, indent=2)
PYEOF
}

update_master_status() {
  local task_id="$1"
  local field="$2"
  local value="$3"
  
  python3 << PYEOF
import json
from datetime import datetime

with open("$STATUS_FILE", 'r') as f:
    status = json.load(f)

if '$task_id' not in status['tasks']:
    status['tasks']['$task_id'] = {}

status['tasks']['$task_id']['$field'] = $value
status['last_updated'] = datetime.utcnow().isoformat() + "Z"

with open("$STATUS_FILE", 'w') as f:
    json.dump(status, f, indent=2)
PYEOF
}

# ============================================
# TASK ASSIGNMENT
# ============================================
declare -A TASK_ASSIGNMENTS

assign_tasks() {
  log_info "Assigning tasks to workers..."
  
  local num_tasks=${#DATASET_FILES[@]}
  local num_workers=${#WORKERS[@]}
  
  if [ "$LOCAL_ONLY" = true ] || [ "$num_workers" -eq 0 ]; then
    # All tasks run locally
    for i in "${!DATASET_FILES[@]}"; do
      TASK_ASSIGNMENTS[$i]="local"
    done
    log_info "All $num_tasks tasks assigned to local machine"
    return
  fi
  
  # Round-robin assignment
  for i in "${!DATASET_FILES[@]}"; do
    local worker_idx=$((i % num_workers))
    TASK_ASSIGNMENTS[$i]="${WORKERS[$worker_idx]}"
  done
  
  log_info "Assigned $num_tasks tasks across $num_workers workers"
  
  # Show assignment summary
  for worker in "${WORKERS[@]}"; do
    local count=0
    for i in "${!TASK_ASSIGNMENTS[@]}"; do
      if [ "${TASK_ASSIGNMENTS[$i]}" = "$worker" ]; then
        count=$((count + 1))
      fi
    done
    log_info "  $worker: $count tasks"
  done
}

# ============================================
# RUN TASK ON WORKER (Uses rct.sh for each task)
# ============================================
run_task_on_worker() {
  local task_idx="$1"
  local dataset="${DATASET_FILES[$task_idx]}"
  local worker="${TASK_ASSIGNMENTS[$task_idx]}"
  
  local task_id
  task_id=$(python3 -c "import json; print(json.load(open('$dataset')).get('instance_id', 'task_$task_idx'))" 2>/dev/null) || task_id="task_$task_idx"
  
  log_info "Starting task $task_id on $worker"
  
  local models_str
  models_str=$(IFS=','; echo "${MODELS[*]}")
  
  update_master_status "$task_id" "worker" "\"$worker\""
  update_master_status "$task_id" "status" "\"running\""
  update_master_status "$task_id" "started_at" "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
  
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would run on $worker: $dataset"
    return 0
  fi
  
  # Build rct.sh command
  local timeout_minutes=$((TIMEOUT / 60))
  local rct_cmd="bash ./evaluation/benchmarks/multi_swe_bench/scripts/rct.sh \
    --models '$models_str' \
    --runs $PASS_AT_N \
    --max-iterations $MAX_ITERATIONS \
    --timeout $timeout_minutes \
    --retries $RETRY_COUNT \
    --instances '$task_id'"
  
  if [ "$worker" = "local" ]; then
    # Run locally
    cd "$VELORA_ROOT"
    (
      source .venv/bin/activate 2>/dev/null || true
      eval "$rct_cmd"
      
      # Update status on completion
      echo '{"status": "completed", "finished_at": "'$(date -Iseconds)'"}' > "/tmp/worker_status_${task_id}.json"
    ) > "/tmp/task_${task_id}.log" 2>&1 &
    
    local pid=$!
    log_info "Started local task $task_id (PID: $pid)"
    update_master_status "$task_id" "pid" "$pid"
  else
    # Run on remote worker
    run_remote "$worker" "cd ${REMOTE_VELORA_PATH} && source .venv/bin/activate 2>/dev/null; nohup $rct_cmd > /tmp/task_${task_id}.log 2>&1 &"
    log_info "Started remote task $task_id on $worker"
  fi
}

# ============================================
# MONITOR PROGRESS
# ============================================
monitor_progress() {
  log_info "Monitoring task progress (interval: ${STATUS_INTERVAL}s)..."
  
  local all_complete=false
  
  while [ "$all_complete" = false ]; do
    sleep "$STATUS_INTERVAL"
    
    all_complete=true
    local tasks_complete=0
    local tasks_running=0
    local tasks_failed=0
    
    for task_idx in "${!DATASET_FILES[@]}"; do
      local dataset="${DATASET_FILES[$task_idx]}"
      local worker="${TASK_ASSIGNMENTS[$task_idx]}"
      local task_id=$(python3 -c "import json; print(json.load(open('$dataset')).get('instance_id', 'task_$task_idx'))" 2>/dev/null)
      
      local status_file="/tmp/worker_status_${task_id}.json"
      local task_status="unknown"
      
      if [ "$worker" = "local" ]; then
        if [ -f "$status_file" ]; then
          task_status=$(python3 -c "import json; print(json.load(open('$status_file')).get('status', 'unknown'))" 2>/dev/null)
        fi
      else
        task_status=$(run_remote "$worker" "cat /tmp/worker_status_${task_id}.json 2>/dev/null | python3 -c \"import sys,json; print(json.load(sys.stdin).get('status', 'unknown'))\"" 2>/dev/null || echo "unknown")
      fi
      
      case "$task_status" in
        completed)
          tasks_complete=$((tasks_complete + 1))
          ;;
        completed_with_errors)
          tasks_complete=$((tasks_complete + 1))
          tasks_failed=$((tasks_failed + 1))
          ;;
        running)
          tasks_running=$((tasks_running + 1))
          all_complete=false
          ;;
        *)
          all_complete=false
          ;;
      esac
    done
    
    log_info "Progress: $tasks_complete complete, $tasks_running running, $tasks_failed with errors"
  done
  
  log_success "All tasks completed!"
}

# ============================================
# SYNC OUTPUTS
# ============================================
sync_all_outputs() {
  log_info "Syncing all outputs to master..."
  
  local output_path="${VELORA_ROOT}/${OUTPUT_BASE}"
  mkdir -p "$output_path"
  
  for worker in "${WORKERS[@]}"; do
    if [ "$worker" != "local" ] && [ -n "$worker" ]; then
      log_info "Syncing from $worker..."
      rsync -avz --progress \
        -e "ssh $SSH_OPTS" \
        "${SSH_USER}@${worker}:${REMOTE_VELORA_PATH}/${OUTPUT_BASE}/" \
        "$output_path/" 2>/dev/null || log_warning "Failed to sync from $worker"
    fi
  done
  
  log_success "Output sync complete"
}

# ============================================
# GENERATE SUMMARY
# ============================================
generate_summary() {
  log_header "BATCH EVALUATION SUMMARY"
  
  python3 << PYEOF
import json
import os
from datetime import datetime

# Load master status
with open("$STATUS_FILE", 'r') as f:
    status = json.load(f)

# Calculate summary
total_tasks = len(status.get('tasks', {}))
completed_tasks = 0
failed_tasks = 0
total_trajectories = 0
successful_trajectories = 0

for task_id, task_info in status.get('tasks', {}).items():
    task_status = task_info.get('status', 'unknown')
    if task_status in ['completed', 'completed_with_errors']:
        completed_tasks += 1
    if task_status == 'completed_with_errors':
        failed_tasks += 1

# Update status
status['status'] = 'completed'
status['completed_at'] = datetime.utcnow().isoformat() + "Z"
status['summary'] = {
    'total_tasks': total_tasks,
    'completed_tasks': completed_tasks,
    'failed_tasks': failed_tasks,
    'success_rate': round(completed_tasks / total_tasks * 100, 1) if total_tasks > 0 else 0
}

with open("$STATUS_FILE", 'w') as f:
    json.dump(status, f, indent=2)

# Print summary
print(f"")
print(f"Configuration: $CONFIG_FILE")
print(f"Models: ${MODELS[*]}")
print(f"Pass@N: $PASS_AT_N")
print(f"")
print(f"Tasks: {completed_tasks}/{total_tasks} completed")
print(f"Failed: {failed_tasks}")
print(f"Success Rate: {status['summary']['success_rate']}%")
print(f"")
print(f"Status file: $STATUS_FILE")
print(f"Log file: $LOG_FILE")
print(f"Outputs: ${VELORA_ROOT}/${OUTPUT_BASE}")
PYEOF
}

# ============================================
# MAIN
# ============================================
main() {
  log_header "BATCH MASTER: Starting Batch Evaluation"
  
  # Initialize log file
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "Batch evaluation started at $(date)" > "$LOG_FILE"
  
  # Parse configuration
  parse_config
  
  # Display configuration
  echo ""
  echo "Configuration:"
  echo "  Config file: $CONFIG_FILE"
  echo "  Pass@N: $PASS_AT_N"
  echo "  Max iterations: $MAX_ITERATIONS"
  echo "  Timeout: ${TIMEOUT}s"
  echo "  Models: ${MODELS[*]}"
  echo "  Workers: ${WORKERS[*]:-local}"
  echo "  Dataset dir: $DATASET_DIR"
  echo "  Output base: $OUTPUT_BASE"
  echo ""
  
  # Setup SSH
  if [ "$LOCAL_ONLY" = false ] && [ ${#WORKERS[@]} -gt 0 ]; then
    setup_ssh
  fi
  
  # Discover datasets
  discover_datasets
  
  echo "Datasets:"
  for i in "${!DATASET_FILES[@]}"; do
    echo "  $((i+1)). ${DATASET_FILES[$i]}"
  done
  echo ""
  
  # Calculate total work
  local total_trajectories=$((${#DATASET_FILES[@]} * ${#MODELS[@]} * PASS_AT_N))
  echo "Total trajectories to generate: $total_trajectories"
  echo "  (${#DATASET_FILES[@]} tasks x ${#MODELS[@]} models x $PASS_AT_N runs)"
  echo ""
  
  # Assign tasks
  assign_tasks
  
  # Dry run check
  if [ "$DRY_RUN" = true ]; then
    log_info "Dry run complete. No tasks were executed."
    exit 0
  fi
  
  # Initialize status
  init_master_status
  
  # Check workers are reachable
  if [ "$LOCAL_ONLY" = false ] && [ ${#WORKERS[@]} -gt 0 ]; then
    log_info "Checking worker connectivity..."
    for worker in "${WORKERS[@]}"; do
      if check_host "$worker" > /dev/null 2>&1; then
        log_success "  $worker: OK"
      else
        log_error "  $worker: UNREACHABLE"
        log_error "Run setup_remote_hosts.sh first or use --local-only"
        exit 1
      fi
    done
  fi
  
  # Start all tasks
  log_header "LAUNCHING TASKS"
  
  for task_idx in "${!DATASET_FILES[@]}"; do
    run_task_on_worker "$task_idx"
    sleep 5  # Stagger task starts
  done
  
  # Monitor progress
  monitor_progress
  
  # Sync outputs
  if [ "$LOCAL_ONLY" = false ] && [ ${#WORKERS[@]} -gt 0 ]; then
    sync_all_outputs
  fi
  
  # Generate summary
  generate_summary
  
  log_header "BATCH EVALUATION COMPLETE"
}

# ============================================
# RUN
# ============================================
cd "$VELORA_ROOT"
main "$@"
