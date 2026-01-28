#!/bin/bash
# run_batch_eval.sh - Batch evaluation orchestrator for Multi-SWE-Bench
#
# This script orchestrates multiple evaluations across:
#   - Local execution (sequential with cleanup)
#   - Distributed execution across multiple AWS instances (parallel)
#
# Features:
#   - Automatic instance division (round-robin, even/odd, etc.)
#   - Memory management with Docker cleanup between runs
#   - Progress tracking and result aggregation
#   - Failure recovery and retry support
#   - SSH-based parallel execution on AWS instances
#
# Usage:
#   Local mode:
#     ./run_batch_eval.sh --model llm.gemini3 --dataset-dir /path/to/dataset/ --max-iter 30
#
#   Distributed mode:
#     ./run_batch_eval.sh --model llm.gemini3 --dataset-dir /path/to/dataset/ \
#       --aws-hosts "host1.aws.com,host2.aws.com" --ssh-key ~/.ssh/id_rsa
#
# Examples:
#   # Run all instances locally
#   ./run_batch_eval.sh -m llm.gemini3 -d ./dataset/ -i 30
#
#   # Run on 2 AWS instances in parallel
#   ./run_batch_eval.sh -m llm.gemini3 -d ./dataset/ -i 30 \
#     --aws-hosts "10.0.0.1,10.0.0.2" --ssh-key ~/.ssh/velora.pem
#
#   # Run on 3 AWS instances with custom SSH user
#   ./run_batch_eval.sh -m llm.gemini3 -d ./dataset/ \
#     --aws-hosts "host1,host2,host3" --ssh-user ec2-user --ssh-key ~/.ssh/key.pem

set -eo pipefail

# ============================================
# SCRIPT CONFIGURATION
# ============================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VELORA_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
EVAL_SCRIPT="$SCRIPT_DIR/run_full_eval_with_s3.sh"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="$VELORA_ROOT/evaluation/batch_logs/$TIMESTAMP"

# Default values
MODEL_CONFIG=""
DATASET_DIR=""
EVAL_LIMIT=1
MAX_ITER=30
NUM_WORKERS=1
AGENT="CodeActAgent"
AWS_HOSTS=""
SSH_KEY=""
SSH_USER="ubuntu"
SSH_PORT=22
REMOTE_VELORA_PATH="/home/ubuntu/Velora_SWE_Harness-4/VeloraHarness"
DRY_RUN=false
RETRY_FAILED=false
RESUME_FROM=""

# ============================================
# COLOR OUTPUT
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_header() { echo -e "\n${CYAN}============================================${NC}"; echo -e "${CYAN}$1${NC}"; echo -e "${CYAN}============================================${NC}"; }

# ============================================
# USAGE
# ============================================
usage() {
  cat << EOF
Usage: $0 [OPTIONS]

Required:
  -m, --model MODEL_CONFIG    LLM config from config.toml (e.g., llm.gemini3, llm.gpt)
  -d, --dataset-dir DIR       Directory containing .jsonl instance files

Optional - Evaluation:
  -i, --max-iter NUM          Max iterations per instance (default: 30)
  -l, --eval-limit NUM        Eval limit per instance (default: 1)
  -w, --workers NUM           Workers per evaluation (default: 1)
  -a, --agent AGENT           Agent class (default: CodeActAgent)

Optional - AWS Distributed Mode:
  --aws-hosts HOSTS           Comma-separated list of AWS hostnames/IPs
  --ssh-key PATH              Path to SSH private key
  --ssh-user USER             SSH username (default: ubuntu)
  --ssh-port PORT             SSH port (default: 22)
  --remote-path PATH          Velora path on remote hosts (default: $REMOTE_VELORA_PATH)

Optional - Control:
  --dry-run                   Show what would be executed without running
  --retry-failed              Only retry previously failed instances
  --resume-from ID            Resume from specific instance ID
  --help                      Show this help message

Examples:
  # Local sequential execution
  $0 -m llm.gemini3 -d ./dataset/ -i 30

  # Distributed across 2 AWS instances
  $0 -m llm.gemini3 -d ./dataset/ --aws-hosts "host1,host2" --ssh-key ~/.ssh/key.pem

  # Dry run to see instance distribution
  $0 -m llm.gemini3 -d ./dataset/ --aws-hosts "h1,h2,h3" --dry-run
EOF
  exit 1
}

# ============================================
# ARGUMENT PARSING
# ============================================
while [[ $# -gt 0 ]]; do
  case $1 in
    -m|--model)
      MODEL_CONFIG="$2"
      shift 2
      ;;
    -d|--dataset-dir)
      DATASET_DIR="$2"
      shift 2
      ;;
    -i|--max-iter)
      MAX_ITER="$2"
      shift 2
      ;;
    -l|--eval-limit)
      EVAL_LIMIT="$2"
      shift 2
      ;;
    -w|--workers)
      NUM_WORKERS="$2"
      shift 2
      ;;
    -a|--agent)
      AGENT="$2"
      shift 2
      ;;
    --aws-hosts)
      AWS_HOSTS="$2"
      shift 2
      ;;
    --ssh-key)
      SSH_KEY="$2"
      shift 2
      ;;
    --ssh-user)
      SSH_USER="$2"
      shift 2
      ;;
    --ssh-port)
      SSH_PORT="$2"
      shift 2
      ;;
    --remote-path)
      REMOTE_VELORA_PATH="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --retry-failed)
      RETRY_FAILED=true
      shift
      ;;
    --resume-from)
      RESUME_FROM="$2"
      shift 2
      ;;
    --help)
      usage
      ;;
    *)
      log_error "Unknown option: $1"
      usage
      ;;
  esac
done

# ============================================
# VALIDATION
# ============================================
if [ -z "$MODEL_CONFIG" ]; then
  log_error "MODEL_CONFIG is required (-m or --model)"
  usage
fi

if [ -z "$DATASET_DIR" ]; then
  log_error "DATASET_DIR is required (-d or --dataset-dir)"
  usage
fi

if [ ! -d "$DATASET_DIR" ]; then
  log_error "Dataset directory not found: $DATASET_DIR"
  exit 1
fi

if [ ! -f "$EVAL_SCRIPT" ]; then
  log_error "Evaluation script not found: $EVAL_SCRIPT"
  exit 1
fi

# Validate SSH key for distributed mode
if [ -n "$AWS_HOSTS" ] && [ -z "$SSH_KEY" ]; then
  log_error "SSH key required for distributed mode (--ssh-key)"
  exit 1
fi

if [ -n "$SSH_KEY" ] && [ ! -f "$SSH_KEY" ]; then
  log_error "SSH key file not found: $SSH_KEY"
  exit 1
fi

# ============================================
# DISCOVER INSTANCES
# ============================================
log_header "DISCOVERING INSTANCES"

DATASET_DIR_ABS=$(realpath "$DATASET_DIR")
log_info "Dataset directory: $DATASET_DIR_ABS"

# Find all .jsonl files
mapfile -t ALL_INSTANCES < <(find "$DATASET_DIR_ABS" -maxdepth 1 -name "*.jsonl" -type f | sort)

if [ ${#ALL_INSTANCES[@]} -eq 0 ]; then
  log_error "No .jsonl files found in $DATASET_DIR_ABS"
  exit 1
fi

log_info "Found ${#ALL_INSTANCES[@]} instance(s)"

# Extract instance IDs for display
declare -A INSTANCE_IDS
for i in "${!ALL_INSTANCES[@]}"; do
  file="${ALL_INSTANCES[$i]}"
  instance_id=$(cat "$file" | python3 -c "import sys,json; print(json.load(sys.stdin).get('instance_id','unknown'))" 2>/dev/null || basename "$file" .jsonl)
  INSTANCE_IDS[$i]="$instance_id"
  echo "  [$i] $instance_id"
done

# Handle resume-from
if [ -n "$RESUME_FROM" ]; then
  log_info "Resuming from instance: $RESUME_FROM"
  RESUME_INDEX=-1
  for i in "${!INSTANCE_IDS[@]}"; do
    if [ "${INSTANCE_IDS[$i]}" == "$RESUME_FROM" ]; then
      RESUME_INDEX=$i
      break
    fi
  done
  if [ $RESUME_INDEX -lt 0 ]; then
    log_error "Resume instance not found: $RESUME_FROM"
    exit 1
  fi
  # Slice array from resume index
  ALL_INSTANCES=("${ALL_INSTANCES[@]:$RESUME_INDEX}")

  # CRITICAL: Re-index INSTANCE_IDS to match sliced ALL_INSTANCES
  declare -A NEW_INSTANCE_IDS
  for i in "${!ALL_INSTANCES[@]}"; do
    file="${ALL_INSTANCES[$i]}"
    instance_id=$(cat "$file" | python3 -c "import sys,json; print(json.load(sys.stdin).get('instance_id','unknown'))" 2>/dev/null || basename "$file" .jsonl)
    NEW_INSTANCE_IDS[$i]="$instance_id"
  done
  # Replace old INSTANCE_IDS with re-indexed version
  unset INSTANCE_IDS
  declare -A INSTANCE_IDS
  for i in "${!NEW_INSTANCE_IDS[@]}"; do
    INSTANCE_IDS[$i]="${NEW_INSTANCE_IDS[$i]}"
  done

  log_info "Resuming with ${#ALL_INSTANCES[@]} remaining instance(s)"

  # Display remaining instances
  for i in "${!ALL_INSTANCES[@]}"; do
    echo "  [$i] ${INSTANCE_IDS[$i]}"
  done
fi

# ============================================
# CREATE LOG DIRECTORY
# ============================================
mkdir -p "$LOG_DIR"
log_info "Log directory: $LOG_DIR"

# Save configuration
cat > "$LOG_DIR/config.json" << EOF
{
  "timestamp": "$TIMESTAMP",
  "model_config": "$MODEL_CONFIG",
  "dataset_dir": "$DATASET_DIR_ABS",
  "max_iter": $MAX_ITER,
  "eval_limit": $EVAL_LIMIT,
  "num_workers": $NUM_WORKERS,
  "agent": "$AGENT",
  "aws_hosts": "$AWS_HOSTS",
  "total_instances": ${#ALL_INSTANCES[@]}
}
EOF

# ============================================
# LOCAL EXECUTION MODE
# ============================================
run_local() {
  log_header "LOCAL SEQUENTIAL EXECUTION"
  log_info "Running ${#ALL_INSTANCES[@]} instances sequentially"

  # Progress tracking
  PROGRESS_FILE="$LOG_DIR/progress.json"
  echo '{"completed": [], "failed": [], "in_progress": null}' > "$PROGRESS_FILE"

  COMPLETED=0
  FAILED=0

  for i in "${!ALL_INSTANCES[@]}"; do
    instance_file="${ALL_INSTANCES[$i]}"
    instance_id="${INSTANCE_IDS[$i]}"
    instance_log="$LOG_DIR/${instance_id}.log"

    log_header "INSTANCE $((i+1))/${#ALL_INSTANCES[@]}: $instance_id"

    # Update progress
    python3 << PYEOF
import json
with open("$PROGRESS_FILE", "r") as f:
    p = json.load(f)
p["in_progress"] = "$instance_id"
with open("$PROGRESS_FILE", "w") as f:
    json.dump(p, f, indent=2)
PYEOF

    if [ "$DRY_RUN" = true ]; then
      log_info "[DRY RUN] Would execute:"
      echo "  $EVAL_SCRIPT $MODEL_CONFIG $instance_file $EVAL_LIMIT $MAX_ITER $NUM_WORKERS $AGENT"
      continue
    fi

    # Pre-run cleanup to ensure sufficient memory
    log_info "Pre-run Docker cleanup..."
    docker system prune -f --volumes 2>/dev/null || true

    # Run evaluation
    log_info "Starting evaluation..."
    START_TIME=$(date +%s)

    set +e
    (
      cd "$VELORA_ROOT"
      bash "$EVAL_SCRIPT" "$MODEL_CONFIG" "$instance_file" "$EVAL_LIMIT" "$MAX_ITER" "$NUM_WORKERS" "$AGENT"
    ) 2>&1 | tee "$instance_log"
    EXIT_CODE=${PIPESTATUS[0]}
    set -e

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    # Update progress
    if [ $EXIT_CODE -eq 0 ]; then
      COMPLETED=$((COMPLETED + 1))
      log_success "Instance $instance_id completed in ${DURATION}s"
      python3 << PYEOF
import json
with open("$PROGRESS_FILE", "r") as f:
    p = json.load(f)
p["completed"].append({"id": "$instance_id", "duration": $DURATION})
p["in_progress"] = None
with open("$PROGRESS_FILE", "w") as f:
    json.dump(p, f, indent=2)
PYEOF
    else
      FAILED=$((FAILED + 1))
      log_error "Instance $instance_id failed (exit code: $EXIT_CODE)"
      python3 << PYEOF
import json
with open("$PROGRESS_FILE", "r") as f:
    p = json.load(f)
p["failed"].append({"id": "$instance_id", "exit_code": $EXIT_CODE, "duration": $DURATION})
p["in_progress"] = None
with open("$PROGRESS_FILE", "w") as f:
    json.dump(p, f, indent=2)
PYEOF
    fi

    # Post-run cleanup
    log_info "Post-run Docker cleanup..."
    docker system prune -f 2>/dev/null || true

    # Progress summary
    echo ""
    log_info "Progress: $COMPLETED completed, $FAILED failed, $((${#ALL_INSTANCES[@]} - i - 1)) remaining"
  done

  return 0
}

# ============================================
# DISTRIBUTED EXECUTION MODE
# ============================================
run_distributed() {
  log_header "DISTRIBUTED PARALLEL EXECUTION"

  # Parse AWS hosts
  IFS=',' read -ra HOSTS <<< "$AWS_HOSTS"
  NUM_HOSTS=${#HOSTS[@]}

  log_info "Distributing ${#ALL_INSTANCES[@]} instances across $NUM_HOSTS AWS host(s)"

  # Display host list
  for i in "${!HOSTS[@]}"; do
    echo "  Host $i: ${HOSTS[$i]}"
  done

  # ============================================
  # DIVIDE INSTANCES (Round-Robin)
  # ============================================
  log_header "INSTANCE DISTRIBUTION"

  # Create arrays for each host
  declare -a HOST_INSTANCES
  for i in "${!HOSTS[@]}"; do
    HOST_INSTANCES[$i]=""
  done

  # Round-robin distribution
  for i in "${!ALL_INSTANCES[@]}"; do
    host_idx=$((i % NUM_HOSTS))
    instance_file="${ALL_INSTANCES[$i]}"
    instance_id="${INSTANCE_IDS[$i]}"

    if [ -n "${HOST_INSTANCES[$host_idx]}" ]; then
      HOST_INSTANCES[$host_idx]="${HOST_INSTANCES[$host_idx]}|$instance_file"
    else
      HOST_INSTANCES[$host_idx]="$instance_file"
    fi

    echo "  Instance $i ($instance_id) -> Host $host_idx (${HOSTS[$host_idx]})"
  done

  echo ""
  log_info "Distribution summary:"
  TOTAL_ASSIGNED=0
  for i in "${!HOSTS[@]}"; do
    if [ -z "${HOST_INSTANCES[$i]}" ]; then
      count=0
    else
      # Count pipe-separated items safely
      count=$(echo "${HOST_INSTANCES[$i]}" | tr '|' '\n' | wc -l)
    fi
    TOTAL_ASSIGNED=$((TOTAL_ASSIGNED + count))
    echo "  Host $i (${HOSTS[$i]}): $count instance(s)"
  done

  # Verify no instances are missing or duplicated
  if [ $TOTAL_ASSIGNED -ne ${#ALL_INSTANCES[@]} ]; then
    log_error "Distribution error! Assigned $TOTAL_ASSIGNED but have ${#ALL_INSTANCES[@]} instances"
    exit 1
  fi
  log_success "Verified: All ${#ALL_INSTANCES[@]} instances assigned (no duplicates, no missing)"

  # Save distribution to file for auditability
  DISTRIBUTION_FILE="$LOG_DIR/distribution.json"
  python3 << DISTEOF
import json

distribution = {
    "total_instances": ${#ALL_INSTANCES[@]},
    "num_hosts": $NUM_HOSTS,
    "hosts": {}
}

# Parse host assignments
DISTEOF

  # Build distribution JSON
  echo "{" > "$DISTRIBUTION_FILE"
  echo '  "total_instances": '${#ALL_INSTANCES[@]}',' >> "$DISTRIBUTION_FILE"
  echo '  "num_hosts": '$NUM_HOSTS',' >> "$DISTRIBUTION_FILE"
  echo '  "hosts": {' >> "$DISTRIBUTION_FILE"
  for i in "${!HOSTS[@]}"; do
    host="${HOSTS[$i]}"
    # Convert pipe-separated to JSON array
    if [ -z "${HOST_INSTANCES[$i]}" ]; then
      instances_json="[]"
    else
      instances_json=$(echo "${HOST_INSTANCES[$i]}" | tr '|' '\n' | while read f; do
        id=$(cat "$f" | python3 -c "import sys,json; print(json.load(sys.stdin).get('instance_id','unknown'))" 2>/dev/null || basename "$f" .jsonl)
        echo "\"$id\""
      done | paste -sd, | sed 's/^/[/;s/$/]/')
    fi
    if [ $i -eq $((NUM_HOSTS - 1)) ]; then
      echo "    \"$host\": $instances_json" >> "$DISTRIBUTION_FILE"
    else
      echo "    \"$host\": $instances_json," >> "$DISTRIBUTION_FILE"
    fi
  done
  echo '  }' >> "$DISTRIBUTION_FILE"
  echo '}' >> "$DISTRIBUTION_FILE"

  log_info "Distribution saved to: $DISTRIBUTION_FILE"

  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would distribute and execute as shown above"
    return 0
  fi

  # ============================================
  # PRE-FLIGHT CHECK: VERIFY REMOTE HOSTS
  # ============================================
  log_header "VERIFYING REMOTE HOSTS"

  # SSH uses -p for port, SCP uses -P for port
  SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i $SSH_KEY -p $SSH_PORT"
  SCP_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i $SSH_KEY -P $SSH_PORT"

  HOSTS_OK=true
  for i in "${!HOSTS[@]}"; do
    host="${HOSTS[$i]}"
    log_info "Checking $host..."

    # Test SSH connection
    if ! ssh $SSH_OPTS "${SSH_USER}@${host}" "echo 'SSH OK'" &>/dev/null; then
      log_error "Cannot SSH to $host"
      HOSTS_OK=false
      continue
    fi

    # Check VeloraHarness exists
    if ! ssh $SSH_OPTS "${SSH_USER}@${host}" "[ -d '${REMOTE_VELORA_PATH}' ]"; then
      log_error "VeloraHarness not found on $host at ${REMOTE_VELORA_PATH}"
      HOSTS_OK=false
      continue
    fi

    # Check evaluation script exists
    if ! ssh $SSH_OPTS "${SSH_USER}@${host}" "[ -f '${REMOTE_VELORA_PATH}/evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh' ]"; then
      log_error "Evaluation script not found on $host"
      HOSTS_OK=false
      continue
    fi

    # Check poetry is available
    POETRY_CHECK=$(ssh $SSH_OPTS "${SSH_USER}@${host}" "source ~/.bashrc 2>/dev/null; source ~/.profile 2>/dev/null; export PATH=\$HOME/.local/bin:\$PATH; command -v poetry && poetry --version" 2>/dev/null || echo "NOT_FOUND")
    if [[ "$POETRY_CHECK" == "NOT_FOUND" ]]; then
      log_error "Poetry not found on $host"
      log_info "  Install with: curl -sSL https://install.python-poetry.org | python3 -"
      HOSTS_OK=false
      continue
    fi

    # Ensure poetry dependencies are installed
    log_info "  Installing poetry dependencies on $host (this may take a moment)..."
    POETRY_INSTALL=$(ssh $SSH_OPTS "${SSH_USER}@${host}" "source ~/.bashrc 2>/dev/null; source ~/.profile 2>/dev/null; export PATH=\$HOME/.local/bin:\$PATH; cd ${REMOTE_VELORA_PATH} && poetry install --no-interaction 2>&1" 2>/dev/null || echo "INSTALL_FAILED")
    if [[ "$POETRY_INSTALL" == *"INSTALL_FAILED"* ]]; then
      log_error "Poetry install failed on $host"
      HOSTS_OK=false
      continue
    fi
    log_info "  Poetry dependencies installed on $host"

    # Check Docker is available
    if ! ssh $SSH_OPTS "${SSH_USER}@${host}" "docker info" &>/dev/null; then
      log_error "Docker not accessible on $host"
      HOSTS_OK=false
      continue
    fi

    log_success "$host is ready"
  done

  if [ "$HOSTS_OK" = false ]; then
    log_error "One or more hosts failed pre-flight check. Aborting."
    exit 1
  fi

  log_success "All hosts passed pre-flight check"

  # ============================================
  # SYNC DATASET TO REMOTE HOSTS
  # ============================================
  log_header "SYNCING DATASET TO REMOTE HOSTS"

  for i in "${!HOSTS[@]}"; do
    host="${HOSTS[$i]}"
    log_info "Syncing to $host..."

    # Create remote dataset directory
    ssh $SSH_OPTS "${SSH_USER}@${host}" "mkdir -p ${REMOTE_VELORA_PATH}/dataset_batch_${TIMESTAMP}"

    # Sync only the instances assigned to this host
    IFS='|' read -ra INST_FILES <<< "${HOST_INSTANCES[$i]}"
    for inst_file in "${INST_FILES[@]}"; do
      if [ -n "$inst_file" ]; then
        scp $SCP_OPTS "$inst_file" "${SSH_USER}@${host}:${REMOTE_VELORA_PATH}/dataset_batch_${TIMESTAMP}/"
      fi
    done

    log_success "Synced ${#INST_FILES[@]} files to $host"
  done

  # ============================================
  # LAUNCH PARALLEL EVALUATIONS
  # ============================================
  log_header "LAUNCHING PARALLEL EVALUATIONS"

  # Create worker script that runs on remote hosts
  WORKER_SCRIPT="$LOG_DIR/worker_script.sh"
  cat > "$WORKER_SCRIPT" << 'WORKER_EOF'
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

# Ensure poetry dependencies are installed
echo "Installing poetry dependencies..." | tee -a "$LOG_FILE"
if ! poetry install --no-interaction 2>&1 | tee -a "$LOG_FILE"; then
  echo "WARNING: poetry install had issues, continuing anyway..." | tee -a "$LOG_FILE"
fi

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
WORKER_EOF

  chmod +x "$WORKER_SCRIPT"

  # Copy worker script to all hosts
  for i in "${!HOSTS[@]}"; do
    host="${HOSTS[$i]}"
    scp $SCP_OPTS "$WORKER_SCRIPT" "${SSH_USER}@${host}:${REMOTE_VELORA_PATH}/worker_script_${TIMESTAMP}.sh"
  done

  # Launch workers in parallel using background processes
  declare -a WORKER_PIDS
  declare -a WORKER_LOGS

  for i in "${!HOSTS[@]}"; do
    host="${HOSTS[$i]}"
    remote_log="${REMOTE_VELORA_PATH}/worker_${TIMESTAMP}_host${i}.log"
    local_log="$LOG_DIR/worker_host${i}.log"
    WORKER_LOGS[$i]="$local_log"

    log_info "Launching worker on $host..."

    # Launch worker via SSH in background
    ssh $SSH_OPTS "${SSH_USER}@${host}" "bash ${REMOTE_VELORA_PATH}/worker_script_${TIMESTAMP}.sh \
      '$MODEL_CONFIG' \
      '${REMOTE_VELORA_PATH}/dataset_batch_${TIMESTAMP}' \
      '$MAX_ITER' \
      '$EVAL_LIMIT' \
      '$NUM_WORKERS' \
      '$AGENT' \
      '$REMOTE_VELORA_PATH' \
      '$i' \
      '$remote_log'" &

    WORKER_PIDS[$i]=$!
    log_info "Worker $i started (PID: ${WORKER_PIDS[$i]})"
  done

  # ============================================
  # MONITOR WORKERS
  # ============================================
  log_header "MONITORING WORKERS"

  # Wait for all workers and collect exit codes
  declare -a WORKER_EXIT_CODES
  RUNNING=${#WORKER_PIDS[@]}

  while [ $RUNNING -gt 0 ]; do
    sleep 30

    RUNNING=0
    for i in "${!WORKER_PIDS[@]}"; do
      pid="${WORKER_PIDS[$i]}"
      if [ -n "$pid" ]; then
        if kill -0 "$pid" 2>/dev/null; then
          RUNNING=$((RUNNING + 1))
        else
          wait "$pid" 2>/dev/null
          WORKER_EXIT_CODES[$i]=$?
          WORKER_PIDS[$i]=""
          log_info "Worker $i finished (exit code: ${WORKER_EXIT_CODES[$i]})"
        fi
      fi
    done

    if [ $RUNNING -gt 0 ]; then
      log_info "Status: $RUNNING worker(s) still running..."
    fi
  done

  # ============================================
  # COLLECT RESULTS
  # ============================================
  log_header "COLLECTING RESULTS"

  for i in "${!HOSTS[@]}"; do
    host="${HOSTS[$i]}"
    remote_log="${REMOTE_VELORA_PATH}/worker_${TIMESTAMP}_host${i}.log"
    local_log="${WORKER_LOGS[$i]}"

    log_info "Fetching logs from $host..."
    scp $SCP_OPTS "${SSH_USER}@${host}:${remote_log}" "$local_log" 2>/dev/null || true

    # Fetch evaluation outputs
    log_info "Fetching evaluation outputs from $host..."
    mkdir -p "$LOG_DIR/outputs_host${i}"
    rsync -avz -e "ssh $SSH_OPTS" \
      "${SSH_USER}@${host}:${REMOTE_VELORA_PATH}/evaluation/evaluation_outputs/" \
      "$LOG_DIR/outputs_host${i}/" 2>/dev/null || true
  done

  # ============================================
  # CLEANUP REMOTE HOSTS
  # ============================================
  log_header "CLEANING UP REMOTE HOSTS"

  for i in "${!HOSTS[@]}"; do
    host="${HOSTS[$i]}"
    log_info "Cleaning up $host..."

    ssh $SSH_OPTS "${SSH_USER}@${host}" "
      rm -rf ${REMOTE_VELORA_PATH}/dataset_batch_${TIMESTAMP}
      rm -f ${REMOTE_VELORA_PATH}/worker_script_${TIMESTAMP}.sh
      rm -f ${REMOTE_VELORA_PATH}/worker_${TIMESTAMP}_host${i}.log
      docker system prune -f 2>/dev/null || true
    " 2>/dev/null || true
  done

  log_success "Remote cleanup complete"
  return 0
}

# ============================================
# AGGREGATE RESULTS
# ============================================
aggregate_results() {
  log_header "AGGREGATING RESULTS"

  SUMMARY_FILE="$LOG_DIR/summary.json"

  python3 << PYEOF
import json
import os
import glob

log_dir = "$LOG_DIR"
summary = {
    "timestamp": "$TIMESTAMP",
    "model_config": "$MODEL_CONFIG",
    "total_instances": ${#ALL_INSTANCES[@]},
    "completed": [],
    "failed": [],
    "results": {}
}

# Check for local progress file
progress_file = os.path.join(log_dir, "progress.json")
if os.path.exists(progress_file):
    with open(progress_file) as f:
        progress = json.load(f)
        summary["completed"] = progress.get("completed", [])
        summary["failed"] = progress.get("failed", [])

# Check for distributed worker logs
for log_file in glob.glob(os.path.join(log_dir, "worker_host*.log")):
    try:
        with open(log_file) as f:
            content = f.read()
            # Parse completion status from log
            for line in content.split('\n'):
                if 'COMPLETED' in line and 'Worker' in line:
                    parts = line.split()
                    for p in parts:
                        if p not in ['Worker', 'COMPLETED', ':']:
                            if p not in [x.get('id') for x in summary["completed"]]:
                                summary["completed"].append({"id": p, "source": log_file})
                elif 'FAILED' in line and 'Worker' in line:
                    parts = line.split()
                    for p in parts:
                        if p not in ['Worker', 'FAILED', ':']:
                            if p not in [x.get('id') for x in summary["failed"]]:
                                summary["failed"].append({"id": p, "source": log_file})
    except Exception as e:
        print(f"Warning: Could not parse {log_file}: {e}")

# Scan for report.json files in outputs
for outputs_dir in glob.glob(os.path.join(log_dir, "outputs_host*")):
    for report_file in glob.glob(os.path.join(outputs_dir, "**/report.json"), recursive=True):
        try:
            with open(report_file) as f:
                report = json.load(f)
                for instance_id, details in report.items():
                    summary["results"][instance_id] = {
                        "resolved": details.get("resolved", False),
                        "patch_applied": details.get("patch_successfully_applied", False),
                        "source": report_file
                    }
        except Exception as e:
            print(f"Warning: Could not parse {report_file}: {e}")

# Calculate statistics
summary["stats"] = {
    "total": summary["total_instances"],
    "completed": len(summary["completed"]),
    "failed": len(summary["failed"]),
    "resolved": sum(1 for r in summary["results"].values() if r.get("resolved", False)),
    "patch_applied": sum(1 for r in summary["results"].values() if r.get("patch_applied", False))
}

with open("$SUMMARY_FILE", "w") as f:
    json.dump(summary, f, indent=2)

print(f"Summary saved to: $SUMMARY_FILE")
print("")
print("=" * 60)
print("BATCH EVALUATION SUMMARY")
print("=" * 60)
print(f"Total instances: {summary['stats']['total']}")
print(f"Completed: {summary['stats']['completed']}")
print(f"Failed: {summary['stats']['failed']}")
print(f"Resolved: {summary['stats']['resolved']}")
print(f"Patch Applied: {summary['stats']['patch_applied']}")
print("=" * 60)
PYEOF
}

# ============================================
# MAIN EXECUTION
# ============================================
log_header "VELORA BATCH EVALUATION"
echo "Timestamp: $TIMESTAMP"
echo "Model: $MODEL_CONFIG"
echo "Dataset: $DATASET_DIR_ABS"
echo "Instances: ${#ALL_INSTANCES[@]}"
echo "Max Iterations: $MAX_ITER"

# Calculate number of hosts for display (before HOSTS array is created in run_distributed)
if [ -n "$AWS_HOSTS" ]; then
  IFS=',' read -ra TEMP_HOSTS <<< "$AWS_HOSTS"
  echo "Mode: Distributed (${#TEMP_HOSTS[@]} hosts)"
  unset TEMP_HOSTS
else
  echo "Mode: Local"
fi

if [ -n "$AWS_HOSTS" ]; then
  run_distributed
else
  run_local
fi

aggregate_results

log_header "BATCH EVALUATION COMPLETE"
echo "Logs: $LOG_DIR"
echo "Summary: $LOG_DIR/summary.json"

exit 0
