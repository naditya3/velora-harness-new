#!/usr/bin/env bash
################################################################################
# Instance-Wise Multi-Model Trajectory Generation System
#
# This script generates trajectories for each instance individually across
# multiple AI models, ensuring granular tracking and reproducibility.
#
# Features:
#   - Instance-wise trajectory generation (one trajectory per instance)
#   - Absolute paths throughout for portability
#   - Production-ready error handling and logging
#   - Parallel and sequential execution modes
#   - Real-time progress tracking
#   - Comprehensive result reporting
#
# Models Supported:
#   - Claude Opus 4.6
#   - GPT-5.2
#   - Kimi K2.5
#   - Qwen 3 Coder Plus
#
# Author: Expert Coder
# Date: 2026-02-06
################################################################################

set -eo pipefail

################################################################################
# CONFIGURATION
################################################################################

# Absolute paths
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="/home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness"
readonly DATASET_PATH="${PROJECT_ROOT}/data/repomate_100_tasks.jsonl"
readonly OUTPUT_BASE_DIR="/home/ec2-user/VeloraTrajectories/outputs"
readonly TEMP_DIR="${PROJECT_ROOT}/temp"
readonly CONFIG_DIR="${PROJECT_ROOT}/config"

# Execution settings
readonly AGENT="CodeActAgent"
readonly SPLIT="train"
readonly MAX_ITER=500
readonly NUM_WORKERS=1
readonly EVAL_NOTE="repomate_instance_wise"

# Model temperature configuration
# IMPORTANT: Temperature is set to 1.0 for all models in config.toml
# This ensures diverse and creative trajectory generation
# Temperature=1.0 provides:
#   - Maximum model creativity and exploration
#   - Diverse trajectories across runs
#   - Better coverage of solution space
readonly MODEL_TEMPERATURE=1.0

# Models configuration
readonly MODELS=("opus" "gpt" "kimi" "qwen")
readonly MODEL_NAMES=(
    "Claude Opus 4.6"
    "GPT-5.2"
    "Kimi K2.5"
    "Qwen 3 Coder Plus"
)

# Runtime configuration
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly SESSION_ID="session_${TIMESTAMP}"
readonly LOG_DIR="${OUTPUT_BASE_DIR}/logs/${SESSION_ID}"
readonly TRAJECTORY_OUTPUT_DIR="${OUTPUT_BASE_DIR}/trajectories/${SESSION_ID}"
readonly PROGRESS_DIR="${OUTPUT_BASE_DIR}/progress/${SESSION_ID}"
readonly RESULTS_DIR="${OUTPUT_BASE_DIR}/results/${SESSION_ID}"

# Lock file for concurrent access
readonly LOCK_DIR="${TEMP_DIR}/locks"

# Timeouts (in seconds)
readonly INSTANCE_TIMEOUT=7200  # 2 hours per instance
readonly GLOBAL_TIMEOUT=259200  # 72 hours total

################################################################################
# INITIALIZATION
################################################################################

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Initialize directories
init_directories() {
    local dirs=(
        "${LOG_DIR}"
        "${TRAJECTORY_OUTPUT_DIR}"
        "${PROGRESS_DIR}"
        "${RESULTS_DIR}"
        "${TEMP_DIR}"
        "${LOCK_DIR}"
        "${CONFIG_DIR}"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
    done
}

# Change to project root
cd "${PROJECT_ROOT}"

################################################################################
# LOGGING FUNCTIONS
################################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "${LOG_DIR}/main.log" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "${LOG_DIR}/main.log" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "${LOG_DIR}/main.log" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "${LOG_DIR}/main.log" >&2
}

log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo -e "${MAGENTA}[DEBUG]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "${LOG_DIR}/debug.log" >&2
    fi
}

################################################################################
# UTILITY FUNCTIONS
################################################################################

# Print separator
print_separator() {
    echo "================================================================================"
}

# Print banner
print_banner() {
    print_separator
    echo "  $*"
    print_separator
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Validate prerequisites
validate_prerequisites() {
    log_info "Validating prerequisites..."

    local required_commands=("python3" "jq" "sg" "docker")
    local missing_commands=()

    for cmd in "${required_commands[@]}"; do
        if ! command_exists "$cmd"; then
            missing_commands+=("$cmd")
        fi
    done

    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing_commands[*]}"
        exit 1
    fi

    # Verify dataset exists
    if [[ ! -f "${DATASET_PATH}" ]]; then
        log_error "Dataset not found at: ${DATASET_PATH}"
        log_info "Please create the dataset first using: python3 scripts/prepare_repomate_dataset.py 75"
        exit 1
    fi

    # Verify Docker is running
    if ! sg docker -c "docker info" >/dev/null 2>&1; then
        log_error "Docker is not running or accessible"
        log_info "Try running: sudo systemctl start docker"
        exit 1
    fi

    # Verify temperature configuration in config.toml
    local config_file="${PROJECT_ROOT}/config.toml"
    if [[ -f "${config_file}" ]]; then
        log_info "Verifying temperature settings in config.toml..."

        local temp_issues=0
        for model in "${MODELS[@]}"; do
            local temp=$(grep -A 10 "\[llm.${model}\]" "${config_file}" | grep "^temperature" | awk '{print $3}')
            if [[ -n "${temp}" ]]; then
                if [[ "${temp}" != "1.0" ]]; then
                    log_warning "Model '${model}' has temperature=${temp} (expected 1.0)"
                    temp_issues=$((temp_issues + 1))
                else
                    log_debug "Model '${model}' temperature=${temp} ✓"
                fi
            else
                log_warning "Could not verify temperature for model '${model}'"
            fi
        done

        if [[ ${temp_issues} -eq 0 ]]; then
            log_success "All models configured with temperature=1.0 ✓"
        else
            log_warning "${temp_issues} model(s) have non-standard temperature settings"
            log_info "To ensure temperature=1.0, edit: ${config_file}"
        fi
    else
        log_warning "Config file not found at: ${config_file}"
    fi

    log_success "All prerequisites validated"
}

################################################################################
# DATASET FUNCTIONS
################################################################################

# Extract all instance IDs from dataset
extract_instance_ids() {
    log_info "Extracting instance IDs from dataset..."

    local instance_ids_file="${TEMP_DIR}/instance_ids.txt"

    # Extract instance_id from each line using jq
    jq -r '.instance_id' "${DATASET_PATH}" > "${instance_ids_file}"

    local count=$(wc -l < "${instance_ids_file}")
    log_success "Extracted ${count} instance IDs"

    echo "${instance_ids_file}"
}

# Create single-instance dataset file
create_single_instance_dataset() {
    local instance_id="$1"
    local output_file="${TEMP_DIR}/instance_${instance_id}.jsonl"

    # Extract the specific instance from the dataset
    jq -c "select(.instance_id == \"${instance_id}\")" "${DATASET_PATH}" > "${output_file}"

    if [[ ! -s "${output_file}" ]]; then
        log_error "Failed to create dataset for instance: ${instance_id}"
        return 1
    fi

    echo "${output_file}"
}

################################################################################
# TRAJECTORY GENERATION FUNCTIONS
################################################################################

# Generate trajectory for a single instance with a specific model
run_instance_trajectory() {
    local instance_id="$1"
    local model_config="$2"
    local model_name="$3"

    local instance_dataset
    instance_dataset=$(create_single_instance_dataset "${instance_id}")
    if [[ $? -ne 0 ]]; then
        return 1
    fi

    local log_file="${LOG_DIR}/${model_config}/instance_${instance_id}.log"
    local trajectory_output="${TRAJECTORY_OUTPUT_DIR}/${model_config}/instance_${instance_id}"
    local progress_file="${PROGRESS_DIR}/${model_config}_${instance_id}.status"

    mkdir -p "$(dirname "${log_file}")"
    mkdir -p "${trajectory_output}"
    mkdir -p "$(dirname "${progress_file}")"

    log_info "[${model_name}] Starting instance: ${instance_id}"

    # Mark as in progress
    echo "IN_PROGRESS|$(date +%s)" > "${progress_file}"

    # Set environment
    export PYTHONPATH="${PROJECT_ROOT}:${PYTHONPATH}"
    export USE_INSTANCE_IMAGE=false
    export IMAGE_MAPPING_CSV="/home/ec2-user/VeloraTrajectories/image_mapping.csv"
    # Suppress pathspec deprecation warnings
    export PYTHONWARNINGS="ignore::DeprecationWarning:pathspec"

    # Run trajectory generation with timeout
    local start_time=$(date +%s)
    local exit_code=0

    timeout "${INSTANCE_TIMEOUT}" sg docker -c "PYTHONWARNINGS='ignore::DeprecationWarning:pathspec' IMAGE_MAPPING_CSV=/home/ec2-user/VeloraTrajectories/image_mapping.csv python3 ${PROJECT_ROOT}/evaluation/benchmarks/swe_bench/run_infer.py \
        --agent-cls ${AGENT} \
        --llm-config ${model_config} \
        --max-iterations ${MAX_ITER} \
        --eval-num-workers ${NUM_WORKERS} \
        --dataset ${instance_dataset} \
        --split ${SPLIT} \
        --eval-note ${EVAL_NOTE}_${model_config}_${instance_id} \
        2>&1 | tee ${log_file}" || exit_code=$?

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Update status
    if [[ ${exit_code} -eq 0 ]]; then
        echo "SUCCESS|${end_time}|${duration}" > "${progress_file}"
        log_success "[${model_name}] Instance ${instance_id} completed in ${duration}s"
    elif [[ ${exit_code} -eq 124 ]]; then
        echo "TIMEOUT|${end_time}|${duration}" > "${progress_file}"
        log_error "[${model_name}] Instance ${instance_id} timed out after ${duration}s"
    else
        echo "FAILED|${end_time}|${duration}|${exit_code}" > "${progress_file}"
        log_error "[${model_name}] Instance ${instance_id} failed with exit code ${exit_code}"
    fi

    # Copy output to trajectory directory
    local eval_output_dir="${PROJECT_ROOT}/evaluation/evaluation_outputs/outputs"
    if [[ -d "${eval_output_dir}" ]]; then
        find "${eval_output_dir}" -type f -name "*${instance_id}*" -exec cp {} "${trajectory_output}/" \; 2>/dev/null || true
    fi

    # Cleanup instance dataset
    rm -f "${instance_dataset}"

    return ${exit_code}
}

# Run all instances for a single model
run_model_instances() {
    local model_config="$1"
    local model_name="$2"
    local instance_ids_file="$3"
    local execution_mode="$4"  # serial or parallel

    print_banner "${model_name} - Instance-wise Trajectory Generation"

    local total_instances=$(wc -l < "${instance_ids_file}")
    local completed=0
    local failed=0
    local timed_out=0

    log_info "[${model_name}] Processing ${total_instances} instances in ${execution_mode} mode"

    if [[ "${execution_mode}" == "parallel" ]]; then
        # Parallel execution with job control
        local max_parallel_jobs=${MAX_PARALLEL_INSTANCES:-4}
        local pids=()

        while IFS= read -r instance_id; do
            # Wait if we've reached max parallel jobs
            while [[ ${#pids[@]} -ge ${max_parallel_jobs} ]]; do
                for i in "${!pids[@]}"; do
                    if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                        wait "${pids[$i]}" || true
                        unset 'pids[$i]'
                    fi
                done
                pids=("${pids[@]}")  # Reindex array
                sleep 1
            done

            # Start new instance in background
            run_instance_trajectory "${instance_id}" "${model_config}" "${model_name}" &
            pids+=($!)

            sleep 0.5  # Small delay to prevent overwhelming the system
        done < "${instance_ids_file}"

        # Wait for remaining jobs
        for pid in "${pids[@]}"; do
            wait "${pid}" || true
        done
    else
        # Sequential execution
        local current=0
        while IFS= read -r instance_id; do
            current=$((current + 1))
            log_info "[${model_name}] Processing instance ${current}/${total_instances}: ${instance_id}"

            if run_instance_trajectory "${instance_id}" "${model_config}" "${model_name}"; then
                completed=$((completed + 1))
            else
                failed=$((failed + 1))
            fi

            # Progress update every 5 instances
            if [[ $((current % 5)) -eq 0 ]]; then
                log_info "[${model_name}] Progress: ${current}/${total_instances} (Success: ${completed}, Failed: ${failed})"
            fi
        done < "${instance_ids_file}"
    fi

    # Count results from progress files
    completed=$(grep -c "SUCCESS" "${PROGRESS_DIR}/${model_config}_"*.status 2>/dev/null || echo 0)
    failed=$(grep -c "FAILED" "${PROGRESS_DIR}/${model_config}_"*.status 2>/dev/null || echo 0)
    timed_out=$(grep -c "TIMEOUT" "${PROGRESS_DIR}/${model_config}_"*.status 2>/dev/null || echo 0)

    # Generate model summary
    local summary_file="${RESULTS_DIR}/${model_config}_summary.txt"
    {
        echo "Model: ${model_name}"
        echo "Configuration: ${model_config}"
        echo "Total Instances: ${total_instances}"
        echo "Successful: ${completed}"
        echo "Failed: ${failed}"
        echo "Timed Out: ${timed_out}"
        echo "Success Rate: $(awk "BEGIN {printf \"%.2f\", (${completed}/${total_instances})*100}")%"
        echo "Completion Time: $(date)"
    } > "${summary_file}"

    log_success "[${model_name}] Completed - Success: ${completed}, Failed: ${failed}, Timeout: ${timed_out}"
}

################################################################################
# PROGRESS MONITORING
################################################################################

# Generate real-time progress report
generate_progress_report() {
    local report_file="${RESULTS_DIR}/progress_report.txt"

    {
        print_banner "Instance-wise Trajectory Generation - Progress Report"
        echo "Session ID: ${SESSION_ID}"
        echo "Generated: $(date)"
        echo ""

        for i in "${!MODELS[@]}"; do
            local model="${MODELS[$i]}"
            local model_name="${MODEL_NAMES[$i]}"

            echo "Model: ${model_name} (${model})"
            echo "----------------------------------------"

            local success=$(grep -c "SUCCESS" "${PROGRESS_DIR}/${model}_"*.status 2>/dev/null || echo 0)
            local failed=$(grep -c "FAILED" "${PROGRESS_DIR}/${model}_"*.status 2>/dev/null || echo 0)
            local timeout=$(grep -c "TIMEOUT" "${PROGRESS_DIR}/${model}_"*.status 2>/dev/null || echo 0)
            local in_progress=$(grep -c "IN_PROGRESS" "${PROGRESS_DIR}/${model}_"*.status 2>/dev/null || echo 0)

            echo "  Success: ${success}"
            echo "  Failed: ${failed}"
            echo "  Timeout: ${timeout}"
            echo "  In Progress: ${in_progress}"
            echo ""
        done

        print_separator
    } > "${report_file}"

    cat "${report_file}"
}

################################################################################
# RESULT AGGREGATION
################################################################################

# Aggregate all results
aggregate_results() {
    log_info "Aggregating results..."

    local final_report="${RESULTS_DIR}/final_report.txt"
    local csv_report="${RESULTS_DIR}/results.csv"

    # Create CSV header
    echo "Model,Instance_ID,Status,Duration_Seconds,Exit_Code" > "${csv_report}"

    # Aggregate from all progress files
    for progress_file in "${PROGRESS_DIR}"/*.status; do
        if [[ -f "${progress_file}" ]]; then
            local filename=$(basename "${progress_file}")
            local model_instance="${filename%.status}"
            local model="${model_instance%_*}"
            local instance_id="${model_instance#*_}"

            local status duration exit_code
            IFS='|' read -r status timestamp duration exit_code < "${progress_file}"

            echo "${model},${instance_id},${status},${duration:-0},${exit_code:-0}" >> "${csv_report}"
        fi
    done

    # Generate final summary
    {
        print_banner "Final Results Summary"
        echo "Session ID: ${SESSION_ID}"
        echo "Dataset: $(basename ${DATASET_PATH})"
        echo "Total Instances Processed: $(wc -l < ${TEMP_DIR}/selected_instances.txt 2>/dev/null || wc -l < ${TEMP_DIR}/instance_ids.txt)"
        echo "Completion Time: $(date)"
        echo ""

        for i in "${!MODELS[@]}"; do
            local model="${MODELS[$i]}"
            local model_name="${MODEL_NAMES[$i]}"

            echo "═══════════════════════════════════════"
            echo "  ${model_name}"
            echo "═══════════════════════════════════════"

            if [[ -f "${RESULTS_DIR}/${model}_summary.txt" ]]; then
                cat "${RESULTS_DIR}/${model}_summary.txt" | tail -n +2
            fi
            echo ""
        done

        echo "Output Locations:"
        echo "  Trajectories: ${TRAJECTORY_OUTPUT_DIR}"
        echo "  Logs: ${LOG_DIR}"
        echo "  Results: ${RESULTS_DIR}"
        echo ""

        print_separator
    } > "${final_report}"

    cat "${final_report}"
    log_success "Results aggregated successfully"
}

################################################################################
# MAIN EXECUTION
################################################################################

main() {
    local start_time=$(date +%s)

    print_banner "Instance-Wise Multi-Model Trajectory Generation System"

    # Initialize
    init_directories
    validate_prerequisites

    # Extract instance IDs
    local instance_ids_file
    instance_ids_file=$(extract_instance_ids)
    local total_instances=$(wc -l < "${instance_ids_file}")

    # Display configuration
    log_info "Configuration:"
    log_info "  Dataset: ${DATASET_PATH}"
    log_info "  Total Instances Available: ${total_instances}"
    log_info "  Models: ${#MODELS[@]} (${MODELS[*]})"
    log_info "  Temperature: ${MODEL_TEMPERATURE} (all models)"
    log_info "  Max Iterations: ${MAX_ITER}"
    log_info "  Agent: ${AGENT}"
    log_info "  Session ID: ${SESSION_ID}"
    log_info "  Output Directory: ${TRAJECTORY_OUTPUT_DIR}"
    echo ""

    # Check if number of tasks provided as command-line argument
    local num_tasks_from_args=""
    if [[ $# -gt 0 ]]; then
        num_tasks_from_args="$1"
        if ! [[ "${num_tasks_from_args}" =~ ^[0-9]+$ ]] || [ "${num_tasks_from_args}" -lt 1 ] || [ "${num_tasks_from_args}" -gt "${total_instances}" ]; then
            log_error "Invalid argument. Number of tasks must be between 1 and ${total_instances}"
            echo ""
            echo "Usage: $0 [NUM_TASKS]"
            echo "  NUM_TASKS: Number of tasks to run (1-${total_instances})"
            echo ""
            echo "Examples:"
            echo "  $0 1     # Run 1 task"
            echo "  $0 10    # Run 10 tasks"
            echo "  $0 100   # Run all 100 tasks"
            echo ""
            exit 1
        fi
        log_success "Running ${num_tasks_from_args} tasks (from command-line argument)"
    fi

    # Instance selection
    local selected_instances_file="${instance_ids_file}"

    if [[ -n "${num_tasks_from_args}" ]]; then
        # Use command-line argument - bypass interactive selection
        selected_instances_file="${TEMP_DIR}/selected_instances.txt"
        head -n "${num_tasks_from_args}" "${instance_ids_file}" > "${selected_instances_file}"
        log_info "Will process tasks 1-${num_tasks_from_args}"
        echo ""
    else
        # Interactive mode
        print_separator
        echo "Instance Selection"
        print_separator
        echo "1) Single Instance - Test with one specific instance (quick test)"
        echo "2) All Instances - Process all ${total_instances} instances (full run)"
        echo "3) Custom Number - Specify how many instances to process"
        echo ""

        read -p "Enter your choice (1-3): " -r instance_choice
        echo ""

        case ${instance_choice} in
            1)
                # Single instance selection
            print_separator
            echo "Select a single instance to test:"
            echo ""
            echo "Showing first 10 instances from dataset:"
            echo ""

            # Display first 10 instances with details
            local count=0
            while IFS= read -r instance_id && [ $count -lt 10 ]; do
                count=$((count + 1))
                local instance_info=$(jq -c "select(.instance_id == \"${instance_id}\") | {language, pr_title}" "${DATASET_PATH}" 2>/dev/null)
                local lang=$(echo "$instance_info" | jq -r '.language // "unknown"')
                local title=$(echo "$instance_info" | jq -r '.pr_title // "No title"' | cut -c1-60)
                echo "  [${count}] ID: ${instance_id}"
                echo "      Language: ${lang} | Task: ${title}"
                echo ""
            done < "${instance_ids_file}"

            echo "  [100] Show instance #100"
            echo "  [custom] Enter custom instance ID"
            echo ""

            read -p "Enter your choice (1-10, 100, or 'custom'): " -r single_choice
            echo ""

            local selected_id=""
            if [[ "${single_choice}" == "custom" ]]; then
                read -p "Enter instance ID: " -r selected_id
            elif [[ "${single_choice}" == "100" ]]; then
                selected_id=$(sed -n '100p' "${instance_ids_file}")
                if [[ -z "${selected_id}" ]]; then
                    log_error "Instance #100 not found in dataset"
                    exit 1
                fi
            elif [[ "${single_choice}" =~ ^[0-9]+$ ]] && [ "${single_choice}" -ge 1 ] && [ "${single_choice}" -le 10 ]; then
                selected_id=$(sed -n "${single_choice}p" "${instance_ids_file}")
            else
                log_error "Invalid choice"
                exit 1
            fi

            # Verify instance exists
            if ! grep -q "^${selected_id}$" "${instance_ids_file}"; then
                log_error "Instance ID '${selected_id}' not found in dataset"
                exit 1
            fi

            # Show selected instance details
            log_info "Selected instance details:"
            jq -c "select(.instance_id == \"${selected_id}\") | {instance_id, repo, language, pr_title}" "${DATASET_PATH}"
            echo ""

            # Create single-instance file
            selected_instances_file="${TEMP_DIR}/selected_instances.txt"
            echo "${selected_id}" > "${selected_instances_file}"

            log_success "Will process 1 instance: ${selected_id}"
            ;;

        2)
            # All instances
            log_info "Will process all ${total_instances} instances"
            selected_instances_file="${instance_ids_file}"
            ;;

        3)
            # Custom number
            read -p "Enter number of instances to process (1-${total_instances}): " -r num_instances

            if ! [[ "${num_instances}" =~ ^[0-9]+$ ]] || [ "${num_instances}" -lt 1 ] || [ "${num_instances}" -gt "${total_instances}" ]; then
                log_error "Invalid number. Must be between 1 and ${total_instances}"
                exit 1
            fi

            selected_instances_file="${TEMP_DIR}/selected_instances.txt"
            head -n "${num_instances}" "${instance_ids_file}" > "${selected_instances_file}"

            log_success "Will process first ${num_instances} instances"
            ;;

        *)
            log_error "Invalid choice"
            exit 1
            ;;
        esac
    fi

    local final_instance_count=$(wc -l < "${selected_instances_file}")
    log_info "Final instance count: ${final_instance_count}"
    echo ""

    # Execution mode selection
    local exec_choice=1  # Default to sequential
    if [[ -z "${num_tasks_from_args}" ]]; then
        # Interactive mode only if not using command-line args
        print_separator
        echo "Execution Mode Selection"
        print_separator
        echo "1) Sequential - Process instances one after another (safer, slower)"
        echo "2) Parallel - Process multiple instances simultaneously (faster, resource intensive)"
        echo "3) Sequential Models, Parallel Instances - Each model runs sequentially, but instances in parallel"
        echo "4) Custom - Select specific models"
        echo ""

        read -p "Enter your choice (1-4): " -r exec_choice
        echo ""
    else
        # When using command-line args, default to sequential mode
        log_info "Using SEQUENTIAL execution mode (default for command-line usage)"
        log_info "To use other modes, run the script without arguments for interactive mode"
        echo ""
    fi

    case ${exec_choice} in
        1)
            log_info "Running in SEQUENTIAL mode..."
            for i in "${!MODELS[@]}"; do
                run_model_instances "${MODELS[$i]}" "${MODEL_NAMES[$i]}" "${selected_instances_file}" "serial"

                if [[ $i -lt $((${#MODELS[@]} - 1)) ]]; then
                    log_info "Waiting 10 seconds before next model..."
                    sleep 10
                fi
            done
            ;;

        2)
            log_info "Running in PARALLEL mode (all models and instances)..."
            echo "⚠️  WARNING: This will consume SIGNIFICANT resources!"
            read -p "Are you sure? (y/n): " -r confirm

            if [[ ! ${confirm} =~ ^[Yy]$ ]]; then
                log_warning "Cancelled by user"
                exit 0
            fi

            # Run all models in parallel
            local pids=()
            for i in "${!MODELS[@]}"; do
                run_model_instances "${MODELS[$i]}" "${MODEL_NAMES[$i]}" "${selected_instances_file}" "parallel" &
                pids+=($!)
                sleep 5  # Stagger model starts
            done

            # Wait for all models
            for pid in "${pids[@]}"; do
                wait "${pid}" || true
            done
            ;;

        3)
            log_info "Running SEQUENTIAL models with PARALLEL instances..."
            export MAX_PARALLEL_INSTANCES=4

            for i in "${!MODELS[@]}"; do
                run_model_instances "${MODELS[$i]}" "${MODEL_NAMES[$i]}" "${selected_instances_file}" "parallel"

                if [[ $i -lt $((${#MODELS[@]} - 1)) ]]; then
                    log_info "Waiting 10 seconds before next model..."
                    sleep 10
                fi
            done
            ;;

        4)
            echo "Available models:"
            for i in "${!MODELS[@]}"; do
                echo "  [$((i+1))] ${MODEL_NAMES[$i]}"
            done
            echo ""
            read -p "Enter model numbers (space-separated, e.g., '1 3'): " -r selected

            # Parse selections
            for num in ${selected}; do
                idx=$((num - 1))
                if [[ ${idx} -ge 0 && ${idx} -lt ${#MODELS[@]} ]]; then
                    run_model_instances "${MODELS[$idx]}" "${MODEL_NAMES[$idx]}" "${selected_instances_file}" "serial"
                fi
            done
            ;;

        *)
            log_error "Invalid choice"
            exit 1
            ;;
    esac

    # Generate final results
    echo ""
    aggregate_results

    local end_time=$(date +%s)
    local total_duration=$((end_time - start_time))

    print_banner "ALL TRAJECTORY GENERATION COMPLETE"
    log_success "Total execution time: ${total_duration} seconds ($(awk "BEGIN {printf \"%.2f\", ${total_duration}/3600}") hours)"
    log_info "Results available at: ${RESULTS_DIR}"
    log_info "Trajectories available at: ${TRAJECTORY_OUTPUT_DIR}"
}

# Trap signals for cleanup
trap 'log_error "Script interrupted"; exit 130' INT TERM

# Execute main function
main "$@"
