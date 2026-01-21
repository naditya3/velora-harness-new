#!/bin/bash
# =============================================================================
# Client Task Runner - Trajectory Generation + Evaluation
# =============================================================================
# This script runs OpenHands trajectory generation and then evaluates using
# the client's Repomate harness requirements:
#   - Working directory: /app/repo
#   - Environment: source /saved/ENV
#   - Test command: from dataset
#   - Parser: from dataset test_output_parser field
#
# Usage:
#   ./run_client_task.sh --instance-id <id> --model <llm.gpt|llm.claude|...> [options]
#
# Examples:
#   ./run_client_task.sh --instance-id 1381179272931492 --model llm.gpt
#   ./run_client_task.sh --dataset /path/to/dataset.jsonl --model llm.claude --eval-only
# =============================================================================

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${BASE_DIR:-$HOME/SWETEs7}"
OPENHANDS_DIR="${OPENHANDS_DIR:-$BASE_DIR/OpenHands}"
VELORA_DIR="${VELORA_DIR:-$BASE_DIR/Velora2Pilot2}"
DATASETS_DIR="${DATASETS_DIR:-$VELORA_DIR/datasets}"
DELIVERY_DIR="${DELIVERY_DIR:-$VELORA_DIR/Delivery Pilot 2}"

# Defaults
MODEL="llm.gpt"
MAX_ITERATIONS=300
EVAL_TIMEOUT=600
EVAL_ONLY=false
SKIP_EVAL=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --instance-id|-i)
            INSTANCE_ID="$2"
            shift 2
            ;;
        --dataset|-d)
            DATASET_PATH="$2"
            shift 2
            ;;
        --model|-m)
            MODEL="$2"
            shift 2
            ;;
        --docker-image)
            DOCKER_IMAGE="$2"
            shift 2
            ;;
        --max-iterations)
            MAX_ITERATIONS="$2"
            shift 2
            ;;
        --eval-timeout)
            EVAL_TIMEOUT="$2"
            shift 2
            ;;
        --eval-only)
            EVAL_ONLY=true
            shift
            ;;
        --skip-eval)
            SKIP_EVAL=true
            shift
            ;;
        --output-dir|-o)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --instance-id, -i    Instance ID to process"
            echo "  --dataset, -d        Path to dataset JSONL file"
            echo "  --model, -m          LLM model config (default: llm.gpt)"
            echo "  --docker-image       Docker image name (auto-detected if not provided)"
            echo "  --max-iterations     Max iterations for trajectory (default: 300)"
            echo "  --eval-timeout       Timeout for evaluation in seconds (default: 600)"
            echo "  --eval-only          Only run evaluation (skip trajectory generation)"
            echo "  --skip-eval          Skip evaluation (only run trajectory generation)"
            echo "  --output-dir, -o     Output directory (default: auto-generated)"
            echo "  --help, -h           Show this help message"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate inputs
if [[ -z "$INSTANCE_ID" && -z "$DATASET_PATH" ]]; then
    log_error "Either --instance-id or --dataset must be provided"
    exit 1
fi

# Set up environment
export DOCKER_BUILDKIT=0
export EVAL_DOCKER_IMAGE_PREFIX="${EVAL_DOCKER_IMAGE_PREFIX:-mswebench}"
export USE_INSTANCE_IMAGE="${USE_INSTANCE_IMAGE:-true}"

log_info "=== Client Task Runner ==="
log_info "Model: $MODEL"
log_info "Max iterations: $MAX_ITERATIONS"

# ============================================================================
# Step 1: Prepare Dataset
# ============================================================================
if [[ -z "$DATASET_PATH" ]]; then
    # Create dataset from instance_id
    DATASET_PATH="$DATASETS_DIR/instance_${INSTANCE_ID}.jsonl"
    log_info "Dataset path: $DATASET_PATH"
    
    if [[ ! -f "$DATASET_PATH" ]]; then
        log_warn "Dataset file not found. Please create it or provide --dataset"
        log_info "Expected format: JSONL with instance_id, test_command, test_output_parser, etc."
        exit 1
    fi
fi

# Extract instance info from dataset
INSTANCE_ID=$(head -1 "$DATASET_PATH" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('instance_id','unknown'))")
log_info "Instance ID: $INSTANCE_ID"

# ============================================================================
# Step 2: Determine Docker Image
# ============================================================================
if [[ -z "$DOCKER_IMAGE" ]]; then
    # Try to extract from dataset
    DOCKER_IMAGE=$(head -1 "$DATASET_PATH" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
uri = d.get('image_storage_uri', '')
if uri:
    # Extract image name from URI
    print(uri.split('/')[-1])
else:
    # Fallback to instance_id based
    print(d.get('instance_id', 'unknown'))
" 2>/dev/null || echo "")
fi

log_info "Docker image: $DOCKER_IMAGE"

# Check if image exists
if ! docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "$DOCKER_IMAGE"; then
    log_warn "Docker image '$DOCKER_IMAGE' not found locally"
    log_info "Please load the image first using: docker load < image.tar"
fi

# ============================================================================
# Step 3: Set up output directory
# ============================================================================
MODEL_SHORT=$(echo "$MODEL" | sed 's/llm\.//')
if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$DELIVERY_DIR/${INSTANCE_ID}/${MODEL_SHORT}"
fi
mkdir -p "$OUTPUT_DIR"
log_info "Output directory: $OUTPUT_DIR"

# ============================================================================
# Step 4: Run Trajectory Generation (unless --eval-only)
# ============================================================================
if [[ "$EVAL_ONLY" != "true" ]]; then
    log_info ""
    log_info "=== Step 4: Running Trajectory Generation ==="
    
    cd "$OPENHANDS_DIR"
    
    TRAJECTORY_OUTPUT_DIR="$OPENHANDS_DIR/evaluation/evaluation_outputs/outputs/swe_bench/${MODEL_SHORT}_maxiter_${MAX_ITERATIONS}"
    
    log_info "Running OpenHands inference..."
    
    poetry run python evaluation/benchmarks/swe_bench/run_infer.py \
        --agent-cls CodeActAgent \
        --llm-config "$MODEL" \
        --max-iterations "$MAX_ITERATIONS" \
        --eval-num-workers 1 \
        --dataset "$DATASET_PATH" \
        --split train \
        --eval-n-limit 1 \
        2>&1 | tee "$OUTPUT_DIR/trajectory.log"
    
    # Find the output file
    TRAJECTORY_OUTPUT=$(find "$TRAJECTORY_OUTPUT_DIR" -name "output.jsonl" -type f -mmin -30 | head -1)
    
    if [[ -z "$TRAJECTORY_OUTPUT" ]]; then
        log_warn "Could not find trajectory output in $TRAJECTORY_OUTPUT_DIR"
        TRAJECTORY_OUTPUT=$(find "$OPENHANDS_DIR/evaluation/evaluation_outputs" -name "output.jsonl" -type f -mmin -30 | head -1)
    fi
    
    if [[ -n "$TRAJECTORY_OUTPUT" ]]; then
        log_info "Trajectory output: $TRAJECTORY_OUTPUT"
        cp "$TRAJECTORY_OUTPUT" "$OUTPUT_DIR/trajectory_output.jsonl"
    else
        log_error "No trajectory output found!"
        exit 1
    fi
else
    log_info "Skipping trajectory generation (--eval-only)"
    TRAJECTORY_OUTPUT="$OUTPUT_DIR/trajectory_output.jsonl"
    if [[ ! -f "$TRAJECTORY_OUTPUT" ]]; then
        log_error "Trajectory output not found at $TRAJECTORY_OUTPUT"
        exit 1
    fi
fi

# ============================================================================
# Step 5: Run Evaluation (unless --skip-eval)
# ============================================================================
if [[ "$SKIP_EVAL" != "true" ]]; then
    log_info ""
    log_info "=== Step 5: Running Evaluation with Client Harness ==="
    
    EVAL_OUTPUT_DIR="$OUTPUT_DIR/eval"
    mkdir -p "$EVAL_OUTPUT_DIR"
    
    cd "$VELORA_DIR/scripts"
    
    python3 eval_client_harness.py \
        --trajectory-output "$OUTPUT_DIR/trajectory_output.jsonl" \
        --dataset "$DATASET_PATH" \
        --output-dir "$EVAL_OUTPUT_DIR" \
        --timeout "$EVAL_TIMEOUT" \
        2>&1 | tee "$OUTPUT_DIR/eval.log"
    
    log_info "Evaluation results saved to: $EVAL_OUTPUT_DIR"
else
    log_info "Skipping evaluation (--skip-eval)"
fi

# ============================================================================
# Summary
# ============================================================================
log_info ""
log_info "=== Task Complete ==="
log_info "Instance: $INSTANCE_ID"
log_info "Model: $MODEL"
log_info "Output: $OUTPUT_DIR"

if [[ -f "$OUTPUT_DIR/eval/summary.json" ]]; then
    echo ""
    cat "$OUTPUT_DIR/eval/summary.json"
fi

log_info ""
log_info "Files generated:"
ls -la "$OUTPUT_DIR/"

