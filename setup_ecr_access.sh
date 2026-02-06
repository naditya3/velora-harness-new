#!/usr/bin/env bash
#
# ECR Access Setup Script
# Sets up AWS ECR authentication and pulls Docker images
#

set -e

# Configuration
ECR_REGISTRY="004669175958.dkr.ecr.us-east-1.amazonaws.com"
AWS_REGION="us-east-1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_MAPPING_FILE="${SCRIPT_DIR}/image_mapping.csv"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if required tools are installed
check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing_tools=()

    if ! command -v aws &> /dev/null; then
        missing_tools+=("aws-cli")
    fi

    if ! command -v docker &> /dev/null; then
        missing_tools+=("docker")
    fi

    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_info "Please install the missing tools:"
        for tool in "${missing_tools[@]}"; do
            case $tool in
                aws-cli)
                    echo "  - AWS CLI: https://aws.amazon.com/cli/"
                    ;;
                docker)
                    echo "  - Docker: https://docs.docker.com/get-docker/"
                    ;;
            esac
        done
        return 1
    fi

    log_success "All prerequisites met"
    return 0
}

# Check AWS credentials
check_aws_credentials() {
    log_info "Checking AWS credentials..."

    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials not configured or invalid"
        log_info "Please configure AWS credentials using:"
        echo "  - aws configure"
        echo "  - Or set environment variables: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY"
        return 1
    fi

    local identity=$(aws sts get-caller-identity --output json)
    local account_id=$(echo "$identity" | grep -o '"Account": "[^"]*' | cut -d'"' -f4)
    local user_arn=$(echo "$identity" | grep -o '"Arn": "[^"]*' | cut -d'"' -f4)

    log_success "AWS credentials valid"
    log_info "Account ID: $account_id"
    log_info "User ARN: $user_arn"

    return 0
}

# Authenticate with ECR
ecr_authenticate() {
    log_info "Authenticating with ECR registry: $ECR_REGISTRY"

    if ! aws ecr get-login-password --region "$AWS_REGION" | \
         docker login --username AWS --password-stdin "$ECR_REGISTRY"; then
        log_error "ECR authentication failed"
        return 1
    fi

    log_success "Successfully authenticated with ECR"
    return 0
}

# Verify ECR access
verify_ecr_access() {
    log_info "Verifying ECR access..."

    local registry_id="${ECR_REGISTRY%%.*}"

    if ! aws ecr describe-repositories \
         --registry-id "$registry_id" \
         --region "$AWS_REGION" \
         --max-items 1 &> /dev/null; then
        log_error "ECR access verification failed"
        log_warning "Your AWS account may not have permission to access this registry"
        return 1
    fi

    log_success "ECR access verified"
    return 0
}

# Pull a single image
pull_image() {
    local image_uri="$1"
    local retry_count="${2:-3}"

    for attempt in $(seq 1 "$retry_count"); do
        log_info "Pulling image (attempt $attempt/$retry_count): $image_uri"

        if docker pull "$image_uri"; then
            log_success "Successfully pulled: $image_uri"
            return 0
        else
            log_warning "Pull attempt $attempt failed"
            if [ "$attempt" -lt "$retry_count" ]; then
                sleep 2
            fi
        fi
    done

    log_error "Failed to pull image after $retry_count attempts: $image_uri"
    return 1
}

# Pull images from CSV mapping file
pull_from_mapping() {
    local max_images="${1:-0}"

    if [ ! -f "$IMAGE_MAPPING_FILE" ]; then
        log_error "Image mapping file not found: $IMAGE_MAPPING_FILE"
        return 1
    fi

    log_info "Loading images from: $IMAGE_MAPPING_FILE"

    # Count total images (excluding header)
    local total_images=$(($(wc -l < "$IMAGE_MAPPING_FILE") - 1))

    if [ "$max_images" -gt 0 ] && [ "$max_images" -lt "$total_images" ]; then
        total_images=$max_images
        log_info "Limiting to first $max_images images"
    fi

    local counter=0
    local successful=0
    local failed=0

    # Read CSV and pull images (skip header)
    tail -n +2 "$IMAGE_MAPPING_FILE" | while IFS=',' read -r internal_uri ecr_uri; do
        # Skip if max_images limit reached
        if [ "$max_images" -gt 0 ] && [ "$counter" -ge "$max_images" ]; then
            break
        fi

        counter=$((counter + 1))

        echo ""
        log_info "[$counter/$total_images] Processing image"
        log_info "Internal URI: $internal_uri"
        log_info "ECR URI: $ecr_uri"

        if pull_image "$ecr_uri" 3; then
            successful=$((successful + 1))
        else
            failed=$((failed + 1))
        fi

        # Small delay between pulls
        sleep 1
    done

    echo ""
    log_info "Pull summary:"
    log_success "Successful: $successful"
    if [ "$failed" -gt 0 ]; then
        log_error "Failed: $failed"
    fi

    return 0
}

# List local ECR images
list_local_images() {
    log_info "Listing local ECR images..."

    local images=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "$ECR_REGISTRY" || true)

    if [ -z "$images" ]; then
        log_warning "No local ECR images found"
        return 0
    fi

    local count=$(echo "$images" | wc -l)
    log_success "Found $count local ECR images:"
    echo "$images"

    return 0
}

# Show usage
show_usage() {
    cat << EOF
ECR Access Setup Script

Usage: $0 [COMMAND] [OPTIONS]

Commands:
  setup                 Complete setup (check prerequisites, authenticate, verify)
  auth                  Authenticate with ECR only
  verify                Verify ECR access
  pull [MAX_IMAGES]     Pull images from mapping file (optional: limit to MAX_IMAGES)
  pull-image IMAGE_URI  Pull a specific image
  list                  List local ECR images
  help                  Show this help message

Environment Variables:
  ECR_REGISTRY          ECR registry URL (default: $ECR_REGISTRY)
  AWS_REGION            AWS region (default: $AWS_REGION)

Examples:
  # Complete setup
  $0 setup

  # Pull first 10 images
  $0 pull 10

  # Pull all images
  $0 pull

  # Pull specific image
  $0 pull-image $ECR_REGISTRY/repomate_image_activ_go_test/meroxa_cli:latest

  # List local images
  $0 list

EOF
}

# Main script
main() {
    local command="${1:-help}"

    case "$command" in
        setup)
            log_info "Starting ECR setup..."
            check_prerequisites || exit 1
            check_aws_credentials || exit 1
            ecr_authenticate || exit 1
            verify_ecr_access || exit 1
            log_success "ECR setup complete!"
            ;;

        auth)
            check_prerequisites || exit 1
            check_aws_credentials || exit 1
            ecr_authenticate || exit 1
            ;;

        verify)
            check_prerequisites || exit 1
            check_aws_credentials || exit 1
            verify_ecr_access || exit 1
            ;;

        pull)
            local max_images="${2:-0}"
            check_prerequisites || exit 1
            ecr_authenticate || exit 1
            pull_from_mapping "$max_images"
            ;;

        pull-image)
            if [ -z "$2" ]; then
                log_error "Image URI required"
                echo "Usage: $0 pull-image IMAGE_URI"
                exit 1
            fi
            check_prerequisites || exit 1
            ecr_authenticate || exit 1
            pull_image "$2"
            ;;

        list)
            check_prerequisites || exit 1
            list_local_images
            ;;

        help|--help|-h)
            show_usage
            ;;

        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
