#!/bin/bash
# =============================================================================
# run_tasks_v2.sh - Standardized Trajectory Generation Script
# =============================================================================
# 
# Features:
#   - Built-in model config mapping (qwen -> qwenOP)
#   - Skip logic for already-completed tasks
#   - Docker image download, load, and dual tagging
#   - Disk cleanup after each task
#   - Status tracking via status.json
#   - Resume capability on restart
#   - Port exhaustion prevention
#
# Usage:
#   ./run_tasks_v2.sh              # Run all tasks from my_tasks.json
#   ./run_tasks_v2.sh --status     # Show current status
#   ./run_tasks_v2.sh --dry-run    # Show what would be run without running
#
# =============================================================================

set -o pipefail  # Catch errors in pipes

# ============= Configuration =============
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR=~/SWETEs7
OPENHANDS_DIR="$BASE_DIR/OpenHands"
VELORA_DIR="$BASE_DIR/Velora2Pilot2"
DATASETS_DIR="$VELORA_DIR/datasets"
TASKS_FILE="$VELORA_DIR/my_tasks.json"
LOG_FILE="$VELORA_DIR/run_tasks_v2.log"
STATUS_FILE="$VELORA_DIR/status.json"
IMAGES_DIR="$BASE_DIR/images"
OUTPUTS_DIR="$OPENHANDS_DIR/evaluation/evaluation_outputs/outputs"
S3_BUCKET="s3://kuberha-velora/velora-files/images"

# ============= Environment Setup =============
export PATH="$HOME/.local/bin:$PATH"
export DOCKER_BUILDKIT=0
export LANGUAGE=python
export EVAL_DOCKER_IMAGE_PREFIX=mswebench
export USE_INSTANCE_IMAGE=true

# ============= Logging =============
log() {
    local msg="$(date '+%Y-%m-%d %H:%M:%S') | $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

log_error() {
    log "ERROR: $1"
}

log_info() {
    log "INFO: $1"
}

log_success() {
    log "SUCCESS: $1"
}

# ============= Model Config Mapping =============
get_llm_config() {
    local model="$1"
    case "$model" in
        qwen)
            echo "llm.qwenOP"
            ;;
        *)
            echo "llm.$model"
            ;;
    esac
}

# Get model folder pattern for finding outputs
get_model_pattern() {
    local model="$1"
    case "$model" in
        kimi)
            echo "*kimi*"
            ;;
        gpt)
            echo "*gpt*"
            ;;
        claude)
            echo "*claude*"
            ;;
        qwen)
            echo "*qwen*"
            ;;
        *)
            echo "*$model*"
            ;;
    esac
}

# ============= Completion Check =============
is_model_complete() {
    local task_id="$1"
    local model="$2"
    local pattern=$(get_model_pattern "$model")
    
    # Find output directory for this task/model
    local output_dir=$(find "$OUTPUTS_DIR" -type d -path "*${task_id}*" -name "${pattern}*maxiter*" 2>/dev/null | head -1)
    
    if [[ -z "$output_dir" ]]; then
        return 1  # Not complete - directory doesn't exist
    fi
    
    local output_file="$output_dir/output.jsonl"
    
    if [[ ! -f "$output_file" ]] || [[ ! -s "$output_file" ]]; then
        return 1  # Not complete - file doesn't exist or is empty
    fi
    
    # Use temporary file to avoid subshell variable scoping issue
    # Check ALL lines for complete trajectories (handle duplicates)
    # A complete trajectory has test_result.git_patch with "diff" in it
    local temp_result=$(mktemp)
    local found_valid=false
    
    # Check each line and write result to temp file (avoids subshell issue)
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ -z "$line" ]]; then
            continue
        fi
        
        local has_patch=$(echo "$line" 2>/dev/null | jq -r '.test_result.git_patch // .git_patch // ""' 2>/dev/null)
        if [[ -n "$has_patch" ]] && [[ "$has_patch" != "null" ]] && echo "$has_patch" | grep -q "diff"; then
            echo "true" > "$temp_result"
            found_valid=true
            break
        fi
    done < "$output_file"
    
    # Check temp file result
    if [[ -f "$temp_result" ]] && [[ "$(cat "$temp_result" 2>/dev/null)" == "true" ]]; then
        rm -f "$temp_result"
        return 0  # Complete - has at least one valid git_patch
    fi
    
    rm -f "$temp_result"
    return 1  # Not complete - no valid git_patch found
}

# ============= Clean Output File =============
# Clear existing output.jsonl to prevent appending duplicates
clean_output_file() {
    local task_id="$1"
    local model="$2"
    local pattern=$(get_model_pattern "$model")
    
    # Find output directory
    local output_dir=$(find "$OUTPUTS_DIR" -type d -path "*${task_id}*" -name "${pattern}*maxiter*" 2>/dev/null | head -1)
    
    if [[ -n "$output_dir" ]]; then
        local output_file="$output_dir/output.jsonl"
        if [[ -f "$output_file" ]]; then
            # Backup existing file before clearing (in case of manual inspection)
            if [[ -s "$output_file" ]]; then
                local backup_file="${output_file}.backup.$(date +%Y%m%d_%H%M%S)"
                cp "$output_file" "$backup_file" 2>/dev/null || true
                log_info "Backed up existing output to: $(basename "$backup_file")"
            fi
            # Clear the file to prevent appending
            > "$output_file"
            log_info "Cleared output file to prevent appending duplicates"
        fi
    fi
}

# ============= Docker Image Management =============
setup_docker_image() {
    local instance_id="$1"
    local dataset_file="$2"
    
    # Primary tag format
    local primary_tag="mswebench/sweb.eval.x86_64.${instance_id}:latest"
    
    # Check if primary tag already exists
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${primary_tag}$"; then
        log_info "Docker image already exists: $primary_tag"
        return 0
    fi
    
    # Extract info from dataset
    local base_commit=$(head -1 "$dataset_file" | jq -r '.base_commit')
    local repo=$(head -1 "$dataset_file" | jq -r '.repo')
    local repo_underscore=$(echo "$repo" | tr '/' '_')
    
    # Construct S3 path
    local s3_filename="${repo_underscore}-${base_commit}.tar"
    local s3_path="${S3_BUCKET}/${s3_filename}"
    local local_tar="${IMAGES_DIR}/${s3_filename}"
    
    log_info "Setting up Docker image for $instance_id"
    log_info "S3 path: $s3_path"
    
    # Create images directory
    mkdir -p "$IMAGES_DIR"
    
    # Download from S3 if not cached locally
    if [[ ! -f "$local_tar" ]]; then
        log_info "Downloading from S3..."
        if ! aws s3 cp "$s3_path" "$local_tar" --region us-east-1 2>&1 | tee -a "$LOG_FILE"; then
            log_error "Failed to download from S3: $s3_path"
            return 1
        fi
    else
        log_info "Using cached tar: $local_tar"
    fi
    
    # Verify file exists and has size
    if [[ ! -s "$local_tar" ]]; then
        log_error "Downloaded file is empty or missing: $local_tar"
        rm -f "$local_tar"
        return 1
    fi
    
    # Load Docker image
    log_info "Loading Docker image..."
    local load_output=$(docker load -i "$local_tar" 2>&1)
    local loaded_image=$(echo "$load_output" | grep "Loaded image" | sed 's/Loaded image: //')
    
    if [[ -z "$loaded_image" ]]; then
        log_error "Failed to load Docker image from $local_tar"
        log_error "Load output: $load_output"
        return 1
    fi
    
    log_info "Loaded: $loaded_image"
    
    # Tag with primary format
    log_info "Tagging as: $primary_tag"
    if ! docker tag "$loaded_image" "$primary_tag"; then
        log_error "Failed to tag image as $primary_tag"
        return 1
    fi
    
    # Tag with alternative format (OpenHands sometimes looks for this)
    local repo_m=$(echo "$repo" | sed 's/\//_m_/g')
    local alt_tag="mswebench/${repo_m}:pr-${instance_id}"
    log_info "Also tagging as: $alt_tag"
    docker tag "$loaded_image" "$alt_tag" 2>/dev/null || true
    
    log_success "Docker image ready: $primary_tag"
    return 0
}

cleanup_docker_image() {
    local instance_id="$1"
    local repo="$2"
    local dataset_file="$3"
    
    log_info "Cleaning up Docker resources for $instance_id..."
    
    # Remove primary tag
    docker rmi "mswebench/sweb.eval.x86_64.${instance_id}:latest" 2>/dev/null || true
    
    # Remove alternative tag
    local repo_m=$(echo "$repo" | sed 's/\//_m_/g')
    docker rmi "mswebench/${repo_m}:pr-${instance_id}" 2>/dev/null || true
    
    # Remove OpenHands runtime images (these are ~13GB each and accumulate!)
    log_info "Removing OpenHands runtime images..."
    docker images --format '{{.Repository}}:{{.Tag}}' | grep 'ghcr.io/openhands/runtime' | xargs -r docker rmi -f 2>/dev/null || true
    
    # Remove any dangling/untagged images
    docker images -q --filter "dangling=true" | xargs -r docker rmi -f 2>/dev/null || true
    
    # Remove tar file to save disk space
    if [[ -f "$dataset_file" ]]; then
        local base_commit=$(head -1 "$dataset_file" | jq -r '.base_commit' 2>/dev/null)
        if [[ -n "$base_commit" ]]; then
            local repo_u=$(echo "$repo" | tr '/' '_')
            rm -f "${IMAGES_DIR}/${repo_u}-${base_commit}.tar" 2>/dev/null || true
        fi
    fi
    
    # Prune all unused Docker resources
    docker container prune -f > /dev/null 2>&1 || true
    docker image prune -af > /dev/null 2>&1 || true
    docker volume prune -f > /dev/null 2>&1 || true
    
    # Report disk space
    local disk_usage=$(df -h / | tail -1 | awk '{print $5}')
    log_info "Cleanup complete for $instance_id (Disk: $disk_usage)"
}

# ============= Status Management =============
init_status() {
    if [[ ! -f "$STATUS_FILE" ]]; then
        echo '{"started_at": "'$(date -Iseconds)'", "tasks": {}}' > "$STATUS_FILE"
    fi
}

update_status() {
    local task_id="$1"
    local model="$2"
    local status="$3"  # running, completed, failed, skipped
    
    # Create temp file with updated status
    local tmp_file=$(mktemp)
    jq --arg tid "$task_id" \
       --arg model "$model" \
       --arg status "$status" \
       --arg time "$(date -Iseconds)" \
       '.tasks[$tid][$model] = {"status": $status, "updated_at": $time}' \
       "$STATUS_FILE" > "$tmp_file" && mv "$tmp_file" "$STATUS_FILE"
}

# ============= Dataset Path Resolution =============
find_dataset() {
    local instance_id="$1"
    local repo="$2"
    
    # Try multiple path patterns
    local repo_double=$(echo "$repo" | sed 's/\//__/g')
    local repo_single=$(echo "$repo" | tr '/' '_')
    
    # Pattern 1: owner__repo-instance_id.jsonl
    local path1="$DATASETS_DIR/${repo_double}-${instance_id}.jsonl"
    if [[ -f "$path1" ]]; then
        echo "$path1"
        return 0
    fi
    
    # Pattern 2: Search by instance_id
    local found=$(find "$DATASETS_DIR" -name "*${instance_id}*.jsonl" 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        echo "$found"
        return 0
    fi
    
    return 1
}

# ============= Main Execution =============
run_task_model() {
    local task_id="$1"
    local repo="$2"
    local model="$3"
    local dataset="$4"
    
    local llm_config=$(get_llm_config "$model")
    
    log_info "Running $task_id with $model (config: $llm_config)"
    update_status "$task_id" "$model" "running"
    
    # Clear existing output file to prevent appending duplicates
    # This prevents OpenHands from appending to an existing file if the script restarts
    clean_output_file "$task_id" "$model"
    
    cd "$OPENHANDS_DIR"
    
    # Ensure DOCKER_BUILDKIT=0 is explicitly set for OpenHands
    # This prevents Docker Buildx from trying to pull images from Docker Hub
    export DOCKER_BUILDKIT=0
    
    if DOCKER_BUILDKIT=0 poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
        --agent-cls CodeActAgent \
        --llm-config "$llm_config" \
        --max-iterations 300 \
        --eval-num-workers 1 \
        --dataset "$dataset" \
        --split train \
        --eval-n-limit 1 \
        2>&1 | tee -a "$LOG_FILE"; then
        
        # Wait a moment for file to be fully written
        sleep 2
        
        # Enhanced verification with detailed logging (direct file check)
        local pattern=$(get_model_pattern "$model")
        local output_dir=$(find "$OUTPUTS_DIR" -type d -path "*${task_id}*" -name "${pattern}*maxiter*" 2>/dev/null | head -1)
        
        if [[ -n "$output_dir" ]] && [[ -f "$output_dir/output.jsonl" ]]; then
            local output_file="$output_dir/output.jsonl"
            local error_field=$(tail -1 "$output_file" 2>/dev/null | jq -r '.error // "null"' 2>/dev/null)
            local patch_field=$(tail -1 "$output_file" 2>/dev/null | jq -r '.test_result.git_patch // .git_patch // ""' 2>/dev/null)
            local patch_length=${#patch_field}
            
            log_info "Verification check: error=$error_field, patch_length=$patch_length"
            
            # Direct verification: check error is null and patch contains "diff"
            # Use a more robust check for patch content
            local has_diff=false
            if [[ -n "$patch_field" ]] && [[ "$patch_field" != "null" ]] && [[ ${#patch_field} -gt 0 ]]; then
                # Check if patch contains "diff" (case-insensitive, handle multiline)
                if echo "$patch_field" | grep -qi "diff"; then
                    has_diff=true
                fi
            fi
            
            if [[ "$error_field" == "null" ]] && [[ "$has_diff" == "true" ]]; then
                log_success "Completed: $task_id with $model (direct verification)"
                update_status "$task_id" "$model" "completed"
                return 0
            else
                log_error "Direct verification failed: error=$error_field, has_patch=$has_diff, patch_length=${#patch_field}"
            fi
        else
            log_error "Output file not found for verification: task_id=$task_id, model=$model"
        fi
        
        # Fallback to is_model_complete if direct check didn't find file or validation failed
        if is_model_complete "$task_id" "$model"; then
            log_success "Completed: $task_id with $model (via is_model_complete)"
            update_status "$task_id" "$model" "completed"
            return 0
        else
            log_error "Task ran but no valid git_patch: $task_id with $model"
            update_status "$task_id" "$model" "failed"
            return 1
        fi
    else
        log_error "Failed: $task_id with $model (execution error)"
        update_status "$task_id" "$model" "failed"
        return 1
    fi
}

show_status() {
    echo "=== Current Status ==="
    
    if [[ ! -f "$STATUS_FILE" ]]; then
        echo "No status file found. Run tasks first."
        return
    fi
    
    # Display task status - handle nested structure correctly
    jq -r '.tasks | to_entries[] | 
        .key as $task_id |
        .value | to_entries[] | 
        "\($task_id) [\(.key)]: \(.value.status) (updated: \(.value.updated_at // "unknown"))"' "$STATUS_FILE" 2>/dev/null || {
        echo "Error reading status file. Checking structure..."
        jq '.tasks | keys | length' "$STATUS_FILE" 2>/dev/null && echo "Status file exists but structure may be invalid."
    }
    
    echo ""
    echo "=== Summary ==="
    # Fix: Properly flatten the nested structure and count statuses
    # Structure: .tasks[task_id][model].status
    local completed=$(jq '[.tasks | to_entries[] | .value | to_entries[] | .value.status] | map(select(. == "completed")) | length' "$STATUS_FILE" 2>/dev/null || echo "0")
    local failed=$(jq '[.tasks | to_entries[] | .value | to_entries[] | .value.status] | map(select(. == "failed")) | length' "$STATUS_FILE" 2>/dev/null || echo "0")
    local skipped=$(jq '[.tasks | to_entries[] | .value | to_entries[] | .value.status] | map(select(. == "skipped")) | length' "$STATUS_FILE" 2>/dev/null || echo "0")
    local running=$(jq '[.tasks | to_entries[] | .value | to_entries[] | .value.status] | map(select(. == "running")) | length' "$STATUS_FILE" 2>/dev/null || echo "0")
    
    echo "Completed: $completed"
    echo "Failed: $failed"
    echo "Skipped: $skipped"
    echo "Running: $running"
    
    # Additional info
    local total_tasks=$(jq '.tasks | keys | length' "$STATUS_FILE" 2>/dev/null || echo "0")
    local total_models=$(jq '[.tasks | to_entries[] | .value | to_entries[]] | length' "$STATUS_FILE" 2>/dev/null || echo "0")
    echo ""
    echo "Total tasks tracked: $total_tasks"
    echo "Total model runs tracked: $total_models"
    
    # Show started time if available
    local started=$(jq -r '.started_at // "unknown"' "$STATUS_FILE" 2>/dev/null)
    if [[ "$started" != "unknown" && "$started" != "null" ]]; then
        echo "Started at: $started"
    fi
}

main() {
    local dry_run=false
    
    # Parse arguments
    case "${1:-}" in
        --status)
            show_status
            exit 0
            ;;
        --dry-run)
            dry_run=true
            ;;
        --help)
            echo "Usage: $0 [--status|--dry-run|--help]"
            exit 0
            ;;
    esac
    
    # Check prerequisites
    if [[ ! -f "$TASKS_FILE" ]]; then
        log_error "Tasks file not found: $TASKS_FILE"
        exit 1
    fi
    
    # Initialize
    mkdir -p "$IMAGES_DIR"
    init_status
    
    log "=============================================="
    log "Starting Trajectory Generation v2"
    log "Started at: $(date)"
    log "=============================================="
    
    # Get total tasks
    local total=$(jq 'length' "$TASKS_FILE")
    log_info "Total tasks in queue: $total"
    
    # Process each task
    local current=0
    jq -c '.[]' "$TASKS_FILE" | while read -r task; do
        current=$((current + 1))
        
        local task_id=$(echo "$task" | jq -r '.instance_id')
        local repo=$(echo "$task" | jq -r '.repo')
        local models=$(echo "$task" | jq -r '.models_to_run | join(" ")')
        
        log ""
        log "=============================================="
        log "Task [$current/$total]: $task_id ($repo)"
        log "Models: $models"
        log "=============================================="
        
        # Find dataset
        local dataset=$(find_dataset "$task_id" "$repo")
        if [[ -z "$dataset" ]]; then
            log_error "Dataset not found for $task_id ($repo)"
            continue
        fi
        log_info "Dataset: $dataset"
        
        # Check which models need to run
        local models_to_run=""
        for model in $models; do
            if is_model_complete "$task_id" "$model"; then
                log_info "SKIP: $model already complete for $task_id"
                update_status "$task_id" "$model" "skipped"
            else
                models_to_run="$models_to_run $model"
            fi
        done
        
        # Skip task if all models complete
        if [[ -z "$(echo $models_to_run | tr -d ' ')" ]]; then
            log_info "All models complete for $task_id, skipping task"
            continue
        fi
        
        if $dry_run; then
            log_info "DRY-RUN: Would run models:$models_to_run"
            continue
        fi
        
        # Check disk space before starting (need at least 30GB free)
        local disk_avail=$(df / | tail -1 | awk '{print $4}')
        local disk_avail_gb=$((disk_avail / 1024 / 1024))
        log_info "Disk space available: ${disk_avail_gb}GB"
        
        if [[ $disk_avail_gb -lt 30 ]]; then
            log_info "Low disk space (${disk_avail_gb}GB < 30GB), cleaning up..."
            docker system prune -af --volumes > /dev/null 2>&1 || true
            rm -rf "${IMAGES_DIR}"/* 2>/dev/null || true
            disk_avail=$(df / | tail -1 | awk '{print $4}')
            disk_avail_gb=$((disk_avail / 1024 / 1024))
            log_info "After cleanup: ${disk_avail_gb}GB available"
            
            if [[ $disk_avail_gb -lt 20 ]]; then
                log_error "Still insufficient disk space (${disk_avail_gb}GB), skipping task"
                continue
            fi
        fi
        
        # Setup Docker image
        if ! setup_docker_image "$task_id" "$dataset"; then
            log_error "Failed to setup Docker image, skipping task"
            continue
        fi
        
        # Run each model that needs to run
        for model in $models_to_run; do
            run_task_model "$task_id" "$repo" "$model" "$dataset"
            
            # Clean up between models (OpenHands runtime images are large!)
            log_info "Cleaning up between model runs..."
            docker container prune -f > /dev/null 2>&1 || true
            docker images --format '{{.Repository}}:{{.Tag}}' | grep 'ghcr.io/openhands/runtime' | xargs -r docker rmi -f 2>/dev/null || true
            docker image prune -f > /dev/null 2>&1 || true
        done
        
        # Cleanup after all models for this task
        cleanup_docker_image "$task_id" "$repo" "$dataset"
    done
    
    log ""
    log "=============================================="
    log "All tasks processed"
    log "Finished at: $(date)"
    log "=============================================="
    
    show_status
}

# Run main
main "$@"

