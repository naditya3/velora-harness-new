#!/bin/bash
#
# RCT - Velora Pass@k Evaluation Runner
#
# This script orchestrates pass@k evaluations across multiple models and optionally
# multiple EC2 instances. It's designed to run unattended overnight.
#
# Features:
# - Multi-model evaluation (gemini, claude, gpt)
# - Pass@k evaluation with configurable k
# - TOML configuration file support
# - CLI parameter support (overrides TOML)
# - Multi-EC2 distributed execution
# - Automatic EC2 setup for fresh instances
# - Comprehensive logging and progress tracking
# - Result aggregation and summary generation
#
# Usage Examples:
#     # Using TOML config file
#     ./rct.sh --config rct_config.toml
#
#     # CLI only (single host, single model, all instances)
#     ./rct.sh --models gemini --runs 8
#     
#     # CLI with specific instances
#     ./rct.sh --models gemini,claude,gpt --runs 8 --instances 1769880766122899,1769880766142606
#     
#     # Mixed: TOML config with CLI overrides
#     ./rct.sh --config rct_config.toml --models gemini --runs 4
#     
#     # Distributed across multiple EC2 instances
#     ./rct.sh --models gemini --runs 8 --hosts aws-velora-1,aws-velora-2 --parallel

set -eo pipefail

# =============================================================================
# SCRIPT CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VELORA_HOME="${SCRIPT_DIR%/evaluation/benchmarks/multi_swe_bench/scripts}"

# Model configuration map
get_model_config() {
    local model="$1"
    case "$model" in
        gemini) echo "llm.gemini" ;;
        claude) echo "llm.claudeNonR" ;;
        gpt) echo "llm.gpt" ;;
        *) echo "$model" ;;
    esac
}

# Get display model name (for directory structure)
get_model_display_name() {
    local model="$1"
    case "$model" in
        gemini) echo "Gemini" ;;
        claude) echo "Claude" ;;
        gpt) echo "GPT" ;;
        *) echo "$model" ;;
    esac
}

# Detect benchmark type from dataset path or instance ID
detect_benchmark_type() {
    local dataset="$1"
    local instance_id="$2"
    
    # Check dataset path patterns
    if [[ "$dataset" == *"swelancer"* ]] || [[ "$dataset" == *"expensify"* ]] || [[ "$dataset" == *"Expensify"* ]]; then
        echo "RCT"
    elif [[ "$dataset" == *"swe_lite"* ]] || [[ "$dataset" == *"swe-bench-lite"* ]]; then
        echo "Lite"
    elif [[ "$dataset" == *"lst"* ]] || [[ "$dataset" == *"large_scale"* ]]; then
        echo "LST"
    # Check if instance_id looks like RCT (17-digit timestamp)
    elif [[ "$instance_id" =~ ^[0-9]{16,}$ ]]; then
        echo "RCT"
    else
        echo "SWE-hard"
    fi
}

# =============================================================================
# DEFAULT SETTINGS
# =============================================================================

# Evaluation settings
MAX_ITERATIONS=1000
TIMEOUT_MINUTES=45
RETRIES=3
RUNS=8
NUM_WORKERS=1

# Model and instance selection
MODELS="gemini"
INSTANCES_FILTER="all"
DATASET_DIR="$VELORA_HOME/dataset"

# Host configuration
HOSTS=""
SSH_KEY=""
SSH_USER="ubuntu"
SSH_PORT=22
PARALLEL=false
DISTRIBUTION="by-data"

# Container settings
REUSE_CONTAINER=false
DOCKER_IMAGE="swelancer/unified:latest"
S3_DOCKER_IMAGE="s3://rfp-coding-q1/Images/RCT/Expensify_App-unified_x86_monolith.tar"

# Output settings
OUTPUT_DIR="$VELORA_HOME/evaluation/evaluation_outputs"
CONFIG_TOML="$VELORA_HOME/config.toml"

# Advanced settings
RESUME=false
SKIP_COMPLETED=true
CLEANUP_AFTER_TASK=true
KEEP_BASE_IMAGES=true
DRY_RUN=false
VERBOSE=false

# State tracking
declare -a ALL_RESULTS=()
TOTAL_EVALUATIONS=0
SUCCESSFUL_EVALUATIONS=0
FAILED_EVALUATIONS=0
LOG_FILE=""
START_TIMESTAMP=""

# =============================================================================
# COLORS AND LOGGING
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

setup_logging() {
    local output_dir="$1"
    mkdir -p "$output_dir"
    START_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    LOG_FILE="$output_dir/evaluation_master_${START_TIMESTAMP}.log"
    touch "$LOG_FILE"
}

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local color=""
    
    case "$level" in
        INFO) color="$BLUE" ;;
        SUCCESS) color="$GREEN" ;;
        WARNING) color="$YELLOW" ;;
        ERROR) color="$RED" ;;
        *) color="$NC" ;;
    esac
    
    echo -e "${color}[$timestamp] [$level]${NC} $message"
    if [[ -n "$LOG_FILE" ]]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi
}

log_info() { log "INFO" "$1"; }
log_error() { log "ERROR" "$1"; }
log_warning() { log "WARNING" "$1"; }
log_success() { log "SUCCESS" "$1"; }
log_header() {
    echo -e "\n${CYAN}======================================================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}======================================================================${NC}"
    if [[ -n "$LOG_FILE" ]]; then
        echo "======================================================================" >> "$LOG_FILE"
        echo "$1" >> "$LOG_FILE"
        echo "======================================================================" >> "$LOG_FILE"
    fi
}

# =============================================================================
# TOML CONFIG PARSER
# =============================================================================

parse_toml_config() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        return 1
    fi
    
    log_info "Loading configuration from: $config_file"
    
    # Use Python to parse TOML and output bash variable assignments
    eval $(python3 << PYEOF
import re

def parse_toml_simple(filepath):
    """Simple TOML parser for RCT config format."""
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

config = parse_toml_simple("$config_file")

# Output bash variables
batch = config.get('batch', {})
if 'pass_at_n' in batch:
    print(f"RUNS={batch['pass_at_n']}")
if 'max_iterations' in batch:
    print(f"MAX_ITERATIONS={batch['max_iterations']}")
if 'timeout_per_trajectory' in batch:
    print(f"TIMEOUT_MINUTES={batch['timeout_per_trajectory'] // 60}")
if 'retry_count' in batch:
    print(f"RETRIES={batch['retry_count']}")

models = config.get('models', {})
enabled = models.get('enabled', [])
if isinstance(enabled, list) and enabled:
    print(f"MODELS='{','.join(enabled)}'")

instances = config.get('instances', {})
workers = instances.get('workers', [])
if isinstance(workers, list) and workers:
    print(f"HOSTS='{','.join(workers)}'")
if instances.get('ssh_key'):
    print(f"SSH_KEY='{instances['ssh_key']}'")
if instances.get('ssh_user'):
    print(f"SSH_USER='{instances['ssh_user']}'")
if instances.get('ssh_port'):
    print(f"SSH_PORT={instances['ssh_port']}")

datasets = config.get('datasets', {})
if datasets.get('directory'):
    print(f"DATASET_DIR='{datasets['directory']}'")

output = config.get('output', {})
if output.get('base_dir'):
    print(f"OUTPUT_DIR='{output['base_dir']}'")

cleanup = config.get('cleanup', {})
if 'docker_cleanup_after_task' in cleanup:
    val = 'true' if cleanup['docker_cleanup_after_task'] else 'false'
    print(f"CLEANUP_AFTER_TASK={val}")
if 'keep_base_images' in cleanup:
    val = 'true' if cleanup['keep_base_images'] else 'false'
    print(f"KEEP_BASE_IMAGES={val}")

advanced = config.get('advanced', {})
if 'skip_completed' in advanced:
    val = 'true' if advanced['skip_completed'] else 'false'
    print(f"SKIP_COMPLETED={val}")
if 'max_parallel_per_instance' in advanced:
    print(f"NUM_WORKERS={advanced['max_parallel_per_instance']}")
PYEOF
)
    return 0
}

# =============================================================================
# SSH UTILITIES
# =============================================================================

run_local_command() {
    local command="$1"
    local timeout_seconds="${2:-300}"
    
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Running locally: ${command:0:100}..."
    fi
    
    timeout "$timeout_seconds" bash -c "$command" 2>&1
    return $?
}

run_ssh_command() {
    local host="$1"
    local command="$2"
    local timeout_seconds="${3:-300}"
    
    local ssh_opts="-o ConnectTimeout=30 -o StrictHostKeyChecking=no -o LogLevel=ERROR"
    [[ -n "$SSH_KEY" ]] && ssh_opts="$ssh_opts -i ${SSH_KEY/#\~/$HOME}"
    [[ -n "$SSH_PORT" ]] && [[ "$SSH_PORT" != "22" ]] && ssh_opts="$ssh_opts -p $SSH_PORT"
    
    # Check if host is in SSH config (not an IP)
    local is_ip=false
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        is_ip=true
    fi
    
    local ssh_cmd
    if [[ "$is_ip" == "true" ]]; then
        ssh_cmd="ssh $ssh_opts ${SSH_USER}@${host}"
    else
        ssh_cmd="ssh $ssh_opts $host"
    fi
    
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Running on $host: ${command:0:100}..."
    fi
    
    timeout "$timeout_seconds" $ssh_cmd "$command" 2>&1
    return $?
}

run_command_on_host() {
    local host="$1"
    local command="$2"
    local timeout_seconds="${3:-300}"
    
    if [[ "$host" == "localhost" ]]; then
        run_local_command "$command" "$timeout_seconds"
    else
        run_ssh_command "$host" "$command" "$timeout_seconds"
    fi
    return $?
}

run_scp() {
    local host="$1"
    local local_path="$2"
    local remote_path="$3"
    local to_remote="${4:-true}"
    
    local scp_opts="-o StrictHostKeyChecking=no -o LogLevel=ERROR -r"
    [[ -n "$SSH_KEY" ]] && scp_opts="$scp_opts -i ${SSH_KEY/#\~/$HOME}"
    [[ -n "$SSH_PORT" ]] && [[ "$SSH_PORT" != "22" ]] && scp_opts="$scp_opts -P $SSH_PORT"
    
    local is_ip=false
    [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && is_ip=true
    
    local target
    if [[ "$is_ip" == "true" ]]; then
        target="${SSH_USER}@${host}"
    else
        target="$host"
    fi
    
    if [[ "$to_remote" == "true" ]]; then
        timeout 600 scp $scp_opts "$local_path" "${target}:${remote_path}" 2>&1
    else
        timeout 600 scp $scp_opts "${target}:${remote_path}" "$local_path" 2>&1
    fi
    return $?
}

# =============================================================================
# EC2 SETUP
# =============================================================================

check_ec2_prerequisites() {
    local host="$1"
    
    log_info "Checking prerequisites on $host..."
    
    local results=""
    local output
    
    # Check each prerequisite
    for check in python docker git aws_cli poetry nvm velora_harness docker_image; do
        local cmd=""
        case "$check" in
            python) cmd="python3 --version" ;;
            docker) cmd="docker --version" ;;
            git) cmd="git --version" ;;
            aws_cli) cmd="aws --version" ;;
            poetry) cmd="poetry --version" ;;
            nvm) cmd="source ~/.nvm/nvm.sh && nvm --version" ;;
            velora_harness) cmd="test -d ~/VeloraHarness && echo exists" ;;
            docker_image) cmd="docker images -q $DOCKER_IMAGE" ;;
        esac
        
        output=$(run_ssh_command "$host" "$cmd" 30 2>/dev/null) || true
        if [[ -n "$output" ]]; then
            log_info "  $host: $check ✓"
            results="${results}${check}=ok;"
        else
            log_info "  $host: $check ✗"
            results="${results}${check}=missing;"
        fi
    done
    
    echo "$results"
}

setup_ec2_instance() {
    local host="$1"
    
    log_info "Setting up EC2 instance: $host"
    
    local prereqs
    prereqs=$(check_ec2_prerequisites "$host")
    
    # Python
    if [[ "$prereqs" != *"python=ok"* ]]; then
        log_info "  Installing Python on $host..."
        run_ssh_command "$host" "sudo apt-get update && sudo apt-get install -y python3 python3-pip python3-venv" 600 || true
    fi
    
    # Git
    if [[ "$prereqs" != *"git=ok"* ]]; then
        log_info "  Installing Git on $host..."
        run_ssh_command "$host" "sudo apt-get install -y git" 120 || true
    fi
    
    # Docker
    if [[ "$prereqs" != *"docker=ok"* ]]; then
        log_info "  Installing Docker on $host..."
        run_ssh_command "$host" "
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable' | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io
sudo usermod -aG docker \$USER
" 600 || true
    fi
    
    # AWS CLI
    if [[ "$prereqs" != *"aws_cli=ok"* ]]; then
        log_info "  Installing AWS CLI on $host..."
        run_ssh_command "$host" "
curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o 'awscliv2.zip'
unzip -q awscliv2.zip && sudo ./aws/install && rm -rf aws awscliv2.zip
" 300 || true
    fi
    
    # Poetry
    if [[ "$prereqs" != *"poetry=ok"* ]]; then
        log_info "  Installing Poetry on $host..."
        run_ssh_command "$host" "
curl -sSL https://install.python-poetry.org | python3 -
echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc
" 120 || true
    fi
    
    # NVM and Node
    if [[ "$prereqs" != *"nvm=ok"* ]]; then
        log_info "  Installing NVM and Node on $host..."
        run_ssh_command "$host" "
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
source ~/.nvm/nvm.sh && nvm install 20.15.1 && nvm install 20.18.0
" 300 || true
    fi
    
    # VeloraHarness
    if [[ "$prereqs" != *"velora_harness=ok"* ]]; then
        log_info "  Syncing VeloraHarness to $host..."
        run_scp "$host" "$VELORA_HOME" "~/" true || {
            log_error "  Failed to sync VeloraHarness"
            return 1
        }
    fi
    
    # Copy config.toml
    log_info "  Copying config.toml to $host..."
    run_scp "$host" "$CONFIG_TOML" "~/VeloraHarness/config.toml" true || {
        log_error "  Failed to copy config.toml"
        return 1
    }
    
    # Install Python dependencies
    log_info "  Installing Python dependencies on $host..."
    run_ssh_command "$host" "cd ~/VeloraHarness && python3 -m venv .venv && source .venv/bin/activate && pip install -e . 2>&1 | tail -3" 600 || true
    
    # Load Docker image if not present
    if [[ "$prereqs" != *"docker_image=ok"* ]]; then
        log_info "  Loading Docker image on $host from S3..."
        run_ssh_command "$host" "
aws s3 cp $S3_DOCKER_IMAGE /tmp/docker_image.tar --only-show-errors &&
docker load < /tmp/docker_image.tar &&
rm -f /tmp/docker_image.tar
" 1800 || log_warning "  Docker image load may have failed"
    fi
    
    log_success "  EC2 instance $host setup complete"
    return 0
}

# =============================================================================
# DATASET UTILITIES
# =============================================================================

get_dataset_instances() {
    local dataset_dir="$1"
    local filter="${2:-all}"
    
    dataset_dir="${dataset_dir/#\~/$HOME}"
    
    # Check for instances subdirectory
    if [[ -d "$dataset_dir/instances" ]]; then
        dataset_dir="$dataset_dir/instances"
    fi
    
    local instances=()
    while IFS= read -r -d '' file; do
        local basename=$(basename "$file" .jsonl)
        if [[ "$basename" =~ ^[0-9]+$ ]] || [[ "$basename" =~ ^17[0-9]+ ]]; then
            instances+=("$basename")
        else
            local instance_id
            instance_id=$(head -1 "$file" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('instance_id',''))" 2>/dev/null) || true
            if [[ -n "$instance_id" ]]; then
                instances+=("$instance_id")
            fi
        fi
    done < <(find "$dataset_dir" -maxdepth 1 -name "*.jsonl" -print0 2>/dev/null | sort -z)
    
    # Apply filter
    if [[ "$filter" == "all" ]]; then
        echo "${instances[@]}"
    elif [[ "$filter" == *":"* ]]; then
        local start="${filter%:*}"
        local end="${filter#*:}"
        echo "${instances[@]:$start:$((end-start))}"
    elif [[ "$filter" == *","* ]]; then
        IFS=',' read -ra filter_ids <<< "$filter"
        for id in "${instances[@]}"; do
            for fid in "${filter_ids[@]}"; do
                if [[ "$id" == "$fid" ]]; then
                    echo "$id"
                fi
            done
        done
    else
        for id in "${instances[@]}"; do
            if [[ "$id" == "$filter" ]]; then
                echo "$id"
            fi
        done
    fi
}

# =============================================================================
# DOCKER CLEANUP
# =============================================================================

cleanup_docker() {
    local host="$1"
    
    if [[ "$CLEANUP_AFTER_TASK" != "true" ]]; then
        return 0
    fi
    
    log_info "[$host] Cleaning up Docker..."
    
    local cleanup_cmd="docker container prune -f && docker image prune -f"
    
    if [[ "$KEEP_BASE_IMAGES" != "true" ]]; then
        cleanup_cmd="$cleanup_cmd && docker system prune -af"
    fi
    
    run_command_on_host "$host" "$cleanup_cmd" 300 >/dev/null 2>&1 || true
}

# =============================================================================
# EVALUATION EXECUTION
# =============================================================================

run_single_evaluation() {
    local host="$1"
    local instance_id="$2"
    local model="$3"
    local run_num="$4"
    local timeout_seconds=$((TIMEOUT_MINUTES * 60))
    
    local model_config
    model_config=$(get_model_config "$model")
    
    log_info "[$host] Starting $model run $run_num for $instance_id"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run: $model run $run_num for $instance_id on $host"
        return 0
    fi
    
    local eval_cmd
    local dataset_file
    local velora_path
    
    if [[ "$host" == "localhost" ]]; then
        velora_path="$VELORA_HOME"
        dataset_file="${DATASET_DIR/#\~/$HOME}/instances/${instance_id}.jsonl"
        if [[ ! -f "$dataset_file" ]]; then
            dataset_file="${DATASET_DIR/#\~/$HOME}/${instance_id}.jsonl"
        fi
    else
        velora_path="~/VeloraHarness"
        dataset_file="~/VeloraHarness/dataset/instances/${instance_id}.jsonl"
    fi
    
    # Detect benchmark type for directory structure
    local benchmark_type
    benchmark_type=$(detect_benchmark_type "$dataset_file" "$instance_id")
    
    # Get display model name for directory
    local model_display_name
    model_display_name=$(get_model_display_name "$model")
    
    eval_cmd="
cd $velora_path && source .venv/bin/activate
export USE_SWELANCER_MONOLITH=true
export SWELANCER_MONOLITH_IMAGE='$DOCKER_IMAGE'
export N_RUNS=1
export RUN_NUMBER_OFFSET=$((run_num - 1))

# New output structure environment variables
export BENCHMARK_TYPE='$benchmark_type'
export MODEL_DISPLAY_NAME='$model_display_name'
export RUN_NUMBER=$run_num
export INSTANCE_ID='$instance_id'

bash ./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh \\
    $model_config \\
    $dataset_file \\
    1 \\
    $MAX_ITERATIONS \\
    $NUM_WORKERS
"
    
    # Run with retries
    local attempt
    local result_output=""
    local success=false
    
    for attempt in $(seq 1 $RETRIES); do
        log_info "  [$host] Attempt $attempt/$RETRIES"
        
        result_output=$(run_command_on_host "$host" "$eval_cmd" "$timeout_seconds" 2>&1) || true
        
        if echo "$result_output" | grep -qE "RESOLVED: YES|\"resolved\": true"; then
            success=true
            break
        elif [[ $attempt -lt $RETRIES ]]; then
            log_warning "  [$host] Attempt $attempt failed, retrying in 5s..."
            sleep 5
        fi
    done
    
    # Record result
    if $success; then
        log_info "  [✓] $model run $run_num - $instance_id"
        ((SUCCESSFUL_EVALUATIONS++)) || true
        ALL_RESULTS+=("${instance_id}:${model}:${run_num}:resolved")
    else
        log_info "  [✗] $model run $run_num - $instance_id"
        ((FAILED_EVALUATIONS++)) || true
        ALL_RESULTS+=("${instance_id}:${model}:${run_num}:failed")
    fi
    ((TOTAL_EVALUATIONS++)) || true
    
    return 0
}

run_evaluations_sequential() {
    local host="$1"
    shift
    local -a work_items=("$@")
    
    for item in "${work_items[@]}"; do
        IFS=':' read -r instance_id model run_num <<< "$item"
        run_single_evaluation "$host" "$instance_id" "$model" "$run_num"
        
        # Cleanup between runs if configured
        if [[ "$CLEANUP_AFTER_TASK" == "true" ]] && [[ $((TOTAL_EVALUATIONS % 5)) -eq 0 ]]; then
            cleanup_docker "$host"
        fi
    done
}

# =============================================================================
# RESULT AGGREGATION
# =============================================================================

generate_summary() {
    local output_dir="$1"
    
    local summary_file="$output_dir/evaluation_summary.json"
    
    # Count by model
    local gemini_total=0 gemini_resolved=0
    local claude_total=0 claude_resolved=0
    local gpt_total=0 gpt_resolved=0
    
    for result in "${ALL_RESULTS[@]}"; do
        IFS=':' read -r instance_id model run_num status <<< "$result"
        case "$model" in
            gemini)
                ((gemini_total++)) || true
                [[ "$status" == "resolved" ]] && ((gemini_resolved++)) || true
                ;;
            claude)
                ((claude_total++)) || true
                [[ "$status" == "resolved" ]] && ((claude_resolved++)) || true
                ;;
            gpt)
                ((gpt_total++)) || true
                [[ "$status" == "resolved" ]] && ((gpt_resolved++)) || true
                ;;
        esac
    done
    
    # Generate JSON summary
    local fresh_container="true"
    [[ "$REUSE_CONTAINER" == "true" ]] && fresh_container="false"
    
    cat > "$summary_file" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "settings": {
        "max_iterations": $MAX_ITERATIONS,
        "timeout_minutes": $TIMEOUT_MINUTES,
        "retries": $RETRIES,
        "runs": $RUNS,
        "num_workers": $NUM_WORKERS,
        "fresh_container": $fresh_container,
        "models": "$MODELS",
        "instances_filter": "$INSTANCES_FILTER"
    },
    "total_evaluations": $TOTAL_EVALUATIONS,
    "successful_evaluations": $SUCCESSFUL_EVALUATIONS,
    "failed_evaluations": $FAILED_EVALUATIONS,
    "results_by_model": {
EOF

    local first=true
    if [[ $gemini_total -gt 0 ]]; then
        local rate=$(echo "scale=4; $gemini_resolved / $gemini_total" | bc -l 2>/dev/null || echo "0")
        [[ "$first" == "false" ]] && echo "," >> "$summary_file"
        first=false
        echo "        \"gemini\": {\"total\": $gemini_total, \"resolved\": $gemini_resolved, \"pass_rate\": $rate}" >> "$summary_file"
    fi
    if [[ $claude_total -gt 0 ]]; then
        [[ "$first" == "false" ]] && echo "," >> "$summary_file"
        first=false
        local rate=$(echo "scale=4; $claude_resolved / $claude_total" | bc -l 2>/dev/null || echo "0")
        echo "        \"claude\": {\"total\": $claude_total, \"resolved\": $claude_resolved, \"pass_rate\": $rate}" >> "$summary_file"
    fi
    if [[ $gpt_total -gt 0 ]]; then
        [[ "$first" == "false" ]] && echo "," >> "$summary_file"
        first=false
        local rate=$(echo "scale=4; $gpt_resolved / $gpt_total" | bc -l 2>/dev/null || echo "0")
        echo "        \"gpt\": {\"total\": $gpt_total, \"resolved\": $gpt_resolved, \"pass_rate\": $rate}" >> "$summary_file"
    fi
    
    cat >> "$summary_file" << EOF
    }
}
EOF
    
    # Print summary
    log_header "EVALUATION SUMMARY"
    log_info "Total Evaluations: $TOTAL_EVALUATIONS"
    log_info "Successful: $SUCCESSFUL_EVALUATIONS"
    log_info "Failed: $FAILED_EVALUATIONS"
    log_info ""
    log_info "Pass@$RUNS Results:"
    
    if [[ $gemini_total -gt 0 ]]; then
        local rate=$(echo "scale=2; $gemini_resolved * 100 / $gemini_total" | bc -l 2>/dev/null || echo "0")
        log_info "  gemini: ${rate}%"
    fi
    if [[ $claude_total -gt 0 ]]; then
        local rate=$(echo "scale=2; $claude_resolved * 100 / $claude_total" | bc -l 2>/dev/null || echo "0")
        log_info "  claude: ${rate}%"
    fi
    if [[ $gpt_total -gt 0 ]]; then
        local rate=$(echo "scale=2; $gpt_resolved * 100 / $gpt_total" | bc -l 2>/dev/null || echo "0")
        log_info "  gpt: ${rate}%"
    fi
}

download_results() {
    local output_dir="$1"
    local host="$2"
    
    local local_results_dir="$output_dir/host_results"
    mkdir -p "$local_results_dir"
    
    log_info "Downloading results from $host..."
    
    local tar_name="results_${host}_$(date +%Y%m%d_%H%M%S).tar.gz"
    local remote_tar="/tmp/$tar_name"
    
    run_ssh_command "$host" "
cd ~/VeloraHarness/evaluation/evaluation_outputs &&
tar -czf $remote_tar outputs/ 2>/dev/null || echo 'No outputs to tar'
" 300 || true
    
    local local_tar="$local_results_dir/$tar_name"
    if run_scp "$host" "$local_tar" "$remote_tar" false 2>/dev/null; then
        log_success "  Downloaded: $local_tar"
    else
        log_warning "  Failed to download results from $host"
    fi
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

print_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

RCT - Velora Pass@k Evaluation Runner

Configuration:
  --config PATH             Load settings from TOML config file
                            (CLI options override config file values)

Model Settings:
  -m, --models MODELS       Comma-separated models: gemini,claude,gpt (default: gemini)
  -k, --runs RUNS           Number of runs per model per instance (default: $RUNS)
  --max-iterations N        Max iterations for agent (default: $MAX_ITERATIONS)
  --timeout MINUTES         Timeout per retry attempt (default: $TIMEOUT_MINUTES)
  --retries N               Number of retry attempts (default: $RETRIES)

Instance Selection:
  -i, --instances FILTER    Instance filter: all, ID, ID1,ID2, or 0:10 (default: all)
  --dataset-dir DIR         Path to dataset directory

Host Configuration:
  --hosts HOSTS             Comma-separated hostnames or IPs for distributed execution
  --ssh-key PATH            Path to SSH private key
  --ssh-user USER           SSH username (default: $SSH_USER)
  --parallel                Enable parallel execution across hosts

Container Settings:
  --reuse-container         Reuse container between runs (default: fresh)
  --docker-image IMAGE      Docker image to use (default: $DOCKER_IMAGE)

Output:
  -o, --output-dir DIR      Output directory for results
  --config-toml PATH        Path to config.toml with API keys

Advanced:
  --skip-completed          Skip tasks with existing outputs (default: true)
  --cleanup                 Enable Docker cleanup after tasks (default: true)
  --dry-run                 Show what would run without executing
  --verbose                 Enable verbose output
  -h, --help                Show this help message

Examples:
  # Using TOML config
  $(basename "$0") --config rct_config.toml

  # Single model, 8 runs per instance
  $(basename "$0") --models gemini --runs 8

  # Multiple models, specific instances
  $(basename "$0") --models gemini,claude --runs 4 --instances 1769880766122899,1769880766142606

  # Distributed execution
  $(basename "$0") --models gemini --runs 8 --hosts aws-velora-1,aws-velora-2 --parallel
EOF
}

parse_args() {
    local config_file=""
    
    # First pass: look for config file
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                config_file="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    
    # Reset args
    set -- "${ORIGINAL_ARGS[@]}"
    
    # Load config file first if specified
    if [[ -n "$config_file" ]]; then
        parse_toml_config "$config_file" || exit 1
    fi
    
    # Second pass: CLI args (override config)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                shift 2
                ;;
            -m|--models)
                MODELS="$2"
                shift 2
                ;;
            -k|--runs)
                RUNS="$2"
                shift 2
                ;;
            --max-iterations)
                MAX_ITERATIONS="$2"
                shift 2
                ;;
            --timeout)
                TIMEOUT_MINUTES="$2"
                shift 2
                ;;
            --retries)
                RETRIES="$2"
                shift 2
                ;;
            -i|--instances)
                INSTANCES_FILTER="$2"
                shift 2
                ;;
            --dataset-dir)
                DATASET_DIR="$2"
                shift 2
                ;;
            --hosts)
                HOSTS="$2"
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
            --parallel)
                PARALLEL=true
                shift
                ;;
            --reuse-container)
                REUSE_CONTAINER=true
                shift
                ;;
            --docker-image)
                DOCKER_IMAGE="$2"
                shift 2
                ;;
            -o|--output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --config-toml)
                CONFIG_TOML="$2"
                shift 2
                ;;
            --skip-completed)
                SKIP_COMPLETED=true
                shift
                ;;
            --cleanup)
                CLEANUP_AFTER_TASK=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Save original args for two-pass parsing
    ORIGINAL_ARGS=("$@")
    parse_args "$@"
    
    # Setup output directory and logging
    OUTPUT_DIR="${OUTPUT_DIR/#\~/$HOME}"
    mkdir -p "$OUTPUT_DIR"
    setup_logging "$OUTPUT_DIR"
    
    log_header "VELORA PASS@K EVALUATION RUNNER (RCT)"
    
    # Parse models
    IFS=',' read -ra MODEL_LIST <<< "$MODELS"
    log_info "Models: ${MODEL_LIST[*]}"
    log_info "Runs per model (k): $RUNS"
    log_info "Max iterations: $MAX_ITERATIONS"
    log_info "Timeout per attempt: $TIMEOUT_MINUTES minutes"
    log_info "Retries: $RETRIES"
    
    # Parse hosts
    local -a HOSTS_LIST
    if [[ -n "$HOSTS" ]]; then
        IFS=',' read -ra HOSTS_LIST <<< "$HOSTS"
        log_info "Hosts: ${HOSTS_LIST[*]}"
    else
        HOSTS_LIST=("localhost")
        log_info "Running on local host"
    fi
    
    # Setup EC2 instances if needed
    if [[ "${HOSTS_LIST[0]}" != "localhost" ]]; then
        log_info ""
        log_info "Checking/Setting up EC2 instances..."
        for host in "${HOSTS_LIST[@]}"; do
            if ! setup_ec2_instance "$host"; then
                log_error "Failed to setup $host"
                exit 1
            fi
        done
    fi
    
    # Get dataset instances
    DATASET_DIR="${DATASET_DIR/#\~/$HOME}"
    local -a INSTANCES
    readarray -t INSTANCES < <(get_dataset_instances "$DATASET_DIR" "$INSTANCES_FILTER")
    log_info "Dataset instances: ${#INSTANCES[@]}"
    
    if [[ ${#INSTANCES[@]} -eq 0 ]]; then
        log_error "No instances found in dataset!"
        exit 1
    fi
    
    # Build work items
    local -a WORK_ITEMS=()
    for model in "${MODEL_LIST[@]}"; do
        for instance_id in "${INSTANCES[@]}"; do
            for run in $(seq 1 $RUNS); do
                WORK_ITEMS+=("${instance_id}:${model}:${run}")
            done
        done
    done
    log_info "Total tasks: ${#WORK_ITEMS[@]}"
    
    # Dry run check
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info ""
        log_info "DRY RUN - Tasks that would be executed:"
        for item in "${WORK_ITEMS[@]}"; do
            IFS=':' read -r instance_id model run_num <<< "$item"
            log_info "  $model run $run_num for $instance_id"
        done
        log_info ""
        log_info "Dry run complete. No tasks were executed."
        exit 0
    fi
    
    # Run evaluations
    log_info ""
    log_info "Starting evaluations..."
    local start_time=$(date +%s)
    
    if [[ "$PARALLEL" == "true" ]] && [[ ${#HOSTS_LIST[@]} -gt 1 ]]; then
        log_warning "Parallel multi-host execution - running sequentially per host"
        for host in "${HOSTS_LIST[@]}"; do
            run_evaluations_sequential "$host" "${WORK_ITEMS[@]}" &
        done
        wait
    else
        run_evaluations_sequential "${HOSTS_LIST[0]}" "${WORK_ITEMS[@]}"
    fi
    
    local end_time=$(date +%s)
    local total_time=$((end_time - start_time))
    local hours=$(echo "scale=2; $total_time / 3600" | bc -l 2>/dev/null || echo "0")
    log_info "Total evaluation time: ${hours} hours"
    
    # Download results from remote hosts
    if [[ "${HOSTS_LIST[0]}" != "localhost" ]]; then
        log_info ""
        log_info "Downloading results from hosts..."
        for host in "${HOSTS_LIST[@]}"; do
            download_results "$OUTPUT_DIR" "$host"
        done
    fi
    
    # Generate summary
    log_info ""
    generate_summary "$OUTPUT_DIR"
    
    # Create final results tar archive
    log_info ""
    log_info "Creating results archive..."
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local tar_name="evaluation_results_${timestamp}.tar.gz"
    local tar_path="$OUTPUT_DIR/$tar_name"
    
    (cd "$OUTPUT_DIR" && tar -czf "$tar_name" evaluation_master_*.log evaluation_summary.json outputs/ 2>/dev/null) || true
    
    if [[ -f "$tar_path" ]]; then
        log_success "Results archive created: $tar_path"
        log_info "To download: scp <host>:$tar_path ./"
    else
        log_warning "Failed to create results archive"
    fi
    
    log_info ""
    log_info "Results saved to: $OUTPUT_DIR"
    log_success "Evaluation complete!"
}

# Run main
main "$@"
