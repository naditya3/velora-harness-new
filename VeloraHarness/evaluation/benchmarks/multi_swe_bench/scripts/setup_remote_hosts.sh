#!/bin/bash
# setup_remote_hosts.sh - Setup and verify remote AWS hosts for batch evaluation
#
# This script checks remote hosts and fixes any issues:
#   - Verifies SSH connectivity
#   - Syncs VeloraHarness if missing
#   - Captures and syncs git commit hash for metadata tracking
#   - Installs Poetry if missing
#   - Verifies and installs all Python dependencies (pandas, datasets, etc.)
#   - Verifies Docker is accessible
#   - Configures AWS credentials
#   - Syncs config.toml with API keys
#   - Creates environment file for consistent evaluation runs
#
# Usage:
#   ./setup_remote_hosts.sh --hosts "host1,host2" --ssh-key ~/.ssh/key.pem [OPTIONS]
#
# Examples:
#   ./setup_remote_hosts.sh --hosts "10.0.0.1,10.0.0.2" --ssh-key ~/.ssh/velora.pem
#   ./setup_remote_hosts.sh --hosts "host1" --ssh-key ~/.ssh/key.pem --check-only

set -eo pipefail

# ============================================
# CONFIGURATION
# ============================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VELORA_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# Default values
AWS_HOSTS=""
SSH_KEY=""
SSH_USER="ubuntu"
SSH_PORT=22
REMOTE_VELORA_PATH="/home/ubuntu/Velora_SWE_Harness-4/VeloraHarness"
CHECK_ONLY=false
FORCE_SYNC=false
SKIP_POETRY_INSTALL=false

# Capture local git commit hash for remote hosts (they don't have .git folder)
LOCAL_GIT_COMMIT=$(git -C "$VELORA_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")

# ============================================
# COLORS
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_header() { echo -e "\n${CYAN}============================================${NC}"; echo -e "${CYAN}$1${NC}"; echo -e "${CYAN}============================================${NC}"; }
log_step() { echo -e "${CYAN}  -->  $1${NC}"; }

# ============================================
# USAGE
# ============================================
usage() {
  cat << EOF
Usage: $0 [OPTIONS]

Required:
  --hosts HOSTS           Comma-separated list of AWS hostnames/IPs
  --ssh-key PATH          Path to SSH private key

Optional:
  --ssh-user USER         SSH username (default: ubuntu)
  --ssh-port PORT         SSH port (default: 22)
  --remote-path PATH      Velora path on remote hosts (default: $REMOTE_VELORA_PATH)
  --check-only            Only check, don't fix issues
  --force-sync            Force sync VeloraHarness even if it exists
  --skip-poetry-install   Skip running 'poetry install' on remote hosts
  --help                  Show this help

Examples:
  # Setup 2 hosts
  $0 --hosts "10.0.0.1,10.0.0.2" --ssh-key ~/.ssh/velora.pem

  # Check only without fixing
  $0 --hosts "host1,host2" --ssh-key ~/.ssh/key.pem --check-only

  # Force re-sync everything
  $0 --hosts "host1" --ssh-key ~/.ssh/key.pem --force-sync
EOF
  exit 1
}

# ============================================
# ARGUMENT PARSING
# ============================================
while [[ $# -gt 0 ]]; do
  case $1 in
    --hosts)
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
    --check-only)
      CHECK_ONLY=true
      shift
      ;;
    --force-sync)
      FORCE_SYNC=true
      shift
      ;;
    --skip-poetry-install)
      SKIP_POETRY_INSTALL=true
      shift
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
if [ -z "$AWS_HOSTS" ]; then
  log_error "--hosts is required"
  usage
fi

if [ -z "$SSH_KEY" ]; then
  log_error "--ssh-key is required"
  usage
fi

if [ ! -f "$SSH_KEY" ]; then
  log_error "SSH key not found: $SSH_KEY"
  exit 1
fi

# Parse hosts
IFS=',' read -ra HOSTS <<< "$AWS_HOSTS"
NUM_HOSTS=${#HOSTS[@]}

# SSH options - note: SSH uses -p for port, SCP uses -P for port
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -i $SSH_KEY -p $SSH_PORT"
SCP_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i $SSH_KEY -P $SSH_PORT"

# ============================================
# HELPER FUNCTIONS
# ============================================

# Run command on remote host with proper environment
run_remote() {
  local host="$1"
  local cmd="$2"
  ssh $SSH_OPTS "${SSH_USER}@${host}" "source ~/.bashrc 2>/dev/null; source ~/.profile 2>/dev/null; export PATH=\$HOME/.local/bin:\$HOME/.poetry/bin:\$PATH; $cmd"
}

# Run poetry command on remote host
run_poetry() {
  local host="$1"
  local cmd="$2"
  run_remote "$host" "cd ${REMOTE_VELORA_PATH} && poetry $cmd"
}

# ============================================
# MAIN
# ============================================
log_header "REMOTE HOST SETUP"
echo "Hosts: ${HOSTS[*]}"
echo "SSH User: $SSH_USER"
echo "Remote Path: $REMOTE_VELORA_PATH"
echo "Local Git Commit: $LOCAL_GIT_COMMIT"
echo "Check Only: $CHECK_ONLY"
echo "Force Sync: $FORCE_SYNC"
echo ""

TOTAL_ISSUES=0
TOTAL_FIXED=0

for i in "${!HOSTS[@]}"; do
  host="${HOSTS[$i]}"
  log_header "HOST $((i+1))/$NUM_HOSTS: $host"

  HOST_ISSUES=0
  HOST_FIXED=0

  # ============================================
  # CHECK 1: SSH Connectivity
  # ============================================
  log_step "Checking SSH connectivity..."
  if ssh $SSH_OPTS "${SSH_USER}@${host}" "echo 'OK'" &>/dev/null; then
    log_success "SSH connection OK"
  else
    log_error "Cannot connect via SSH"
    log_info "  Please verify:"
    log_info "    - Host is reachable: ping $host"
    log_info "    - SSH key is correct: ssh -i $SSH_KEY ${SSH_USER}@${host}"
    log_info "    - Security group allows SSH from this IP"
    TOTAL_ISSUES=$((TOTAL_ISSUES + 1))
    continue  # Can't proceed without SSH
  fi

  # ============================================
  # CHECK 2: VeloraHarness Directory
  # ============================================
  log_step "Checking VeloraHarness installation..."
  VELORA_EXISTS=$(ssh $SSH_OPTS "${SSH_USER}@${host}" "[ -d '${REMOTE_VELORA_PATH}' ] && echo 'YES' || echo 'NO'")

  if [ "$VELORA_EXISTS" = "YES" ] && [ "$FORCE_SYNC" = false ]; then
    log_success "VeloraHarness exists at $REMOTE_VELORA_PATH"
  else
    if [ "$VELORA_EXISTS" = "NO" ]; then
      log_warning "VeloraHarness not found"
    else
      log_info "Force sync requested"
    fi
    HOST_ISSUES=$((HOST_ISSUES + 1))

    if [ "$CHECK_ONLY" = false ]; then
      log_step "Syncing VeloraHarness to $host..."

      # Create parent directory
      ssh $SSH_OPTS "${SSH_USER}@${host}" "mkdir -p $(dirname $REMOTE_VELORA_PATH)"

      # Sync using rsync (excludes large/unnecessary files)
      # Note: .git is excluded because it's large; we track git commit via env file instead
      rsync -avz --progress \
        --exclude '.git' \
        --exclude '__pycache__' \
        --exclude '*.pyc' \
        --exclude '.venv' \
        --exclude 'node_modules' \
        --exclude 'evaluation/evaluation_outputs' \
        --exclude 'evaluation/batch_logs' \
        --exclude '.eval_sessions' \
        --exclude '*.tar' \
        --exclude '*.tar.gz' \
        -e "ssh $SSH_OPTS" \
        "$VELORA_ROOT/" \
        "${SSH_USER}@${host}:${REMOTE_VELORA_PATH}/"

      if [ $? -eq 0 ]; then
        log_success "VeloraHarness synced"
        HOST_FIXED=$((HOST_FIXED + 1))
      else
        log_error "Failed to sync VeloraHarness"
      fi
    else
      log_info "  [CHECK ONLY] Would sync VeloraHarness"
    fi
  fi

  # ============================================
  # CHECK 3: Git Commit Environment File
  # ============================================
  log_step "Setting up git commit tracking..."

  # Create/update the OpenHands environment file with git commit
  # This is needed because remote hosts don't have .git folder
  ENV_FILE="${REMOTE_VELORA_PATH}/.openhands_env"

  if [ "$CHECK_ONLY" = false ]; then
    ssh $SSH_OPTS "${SSH_USER}@${host}" "cat > ${ENV_FILE} << 'ENVEOF'
# OpenHands Environment Configuration
# Auto-generated by setup_remote_hosts.sh
# This file is sourced by evaluation scripts to set environment variables

# Git commit hash from source repository (remote hosts don't have .git folder)
export OPENHANDS_GIT_COMMIT=\"${LOCAL_GIT_COMMIT}\"

# Timestamp of last setup
export OPENHANDS_SETUP_TIME=\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"

# Source host that performed the setup
export OPENHANDS_SOURCE_HOST=\"$(hostname)\"
ENVEOF"
    log_success "Created environment file with git commit: ${LOCAL_GIT_COMMIT:0:8}..."
  else
    log_info "  [CHECK ONLY] Would create environment file with git commit"
  fi

  # ============================================
  # CHECK 4: Evaluation Script
  # ============================================
  log_step "Checking evaluation script..."
  EVAL_SCRIPT_EXISTS=$(ssh $SSH_OPTS "${SSH_USER}@${host}" "[ -f '${REMOTE_VELORA_PATH}/evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_swe.sh' ] && echo 'YES' || echo 'NO'")

  if [ "$EVAL_SCRIPT_EXISTS" = "YES" ]; then
    log_success "Evaluation script exists"
  else
    log_error "Evaluation script not found (should be fixed by VeloraHarness sync)"
    HOST_ISSUES=$((HOST_ISSUES + 1))
  fi

  # ============================================
  # CHECK 5: Python Version
  # ============================================
  log_step "Checking Python version..."
  PYTHON_VERSION=$(ssh $SSH_OPTS "${SSH_USER}@${host}" "python3 --version 2>/dev/null || echo 'NOT_FOUND'")

  if [[ "$PYTHON_VERSION" == *"3.12"* ]] || [[ "$PYTHON_VERSION" == *"3.11"* ]] || [[ "$PYTHON_VERSION" == *"3.10"* ]]; then
    log_success "Python version: $PYTHON_VERSION"
  elif [[ "$PYTHON_VERSION" == "NOT_FOUND" ]]; then
    log_error "Python3 not found"
    HOST_ISSUES=$((HOST_ISSUES + 1))
  else
    log_warning "Python version may be incompatible: $PYTHON_VERSION (recommend 3.10+)"
  fi

  # ============================================
  # CHECK 6: Poetry Installation
  # ============================================
  log_step "Checking Poetry installation..."
  POETRY_VERSION=$(run_remote "$host" "poetry --version 2>/dev/null || echo 'NOT_FOUND'")

  if [[ "$POETRY_VERSION" != "NOT_FOUND" ]]; then
    log_success "Poetry installed: $POETRY_VERSION"
  else
    log_warning "Poetry not found"
    HOST_ISSUES=$((HOST_ISSUES + 1))

    if [ "$CHECK_ONLY" = false ]; then
      log_step "Installing Poetry on $host..."
      ssh $SSH_OPTS "${SSH_USER}@${host}" "curl -sSL https://install.python-poetry.org | python3 -"

      # Verify installation
      POETRY_CHECK=$(run_remote "$host" "poetry --version 2>/dev/null || echo 'FAILED'")
      if [[ "$POETRY_CHECK" != "FAILED" ]]; then
        log_success "Poetry installed: $POETRY_CHECK"
        HOST_FIXED=$((HOST_FIXED + 1))
      else
        log_error "Failed to install Poetry"
      fi
    else
      log_info "  [CHECK ONLY] Would install Poetry"
    fi
  fi

  # ============================================
  # CHECK 7: Poetry Dependencies (comprehensive check)
  # ============================================
  if [ "$SKIP_POETRY_INSTALL" = false ]; then
    log_step "Checking Poetry dependencies (comprehensive)..."

    # Check for ALL critical dependencies, not just pandas and datasets
    CRITICAL_IMPORTS="import pandas; import datasets; import openhands; print('ALL_OK')"
    DEPS_CHECK=$(run_poetry "$host" "run python -c '$CRITICAL_IMPORTS' 2>&1 || echo 'IMPORT_FAILED'")

    if [[ "$DEPS_CHECK" == *"ALL_OK"* ]]; then
      log_success "All critical dependencies installed"
    else
      log_warning "Dependencies missing or incomplete"
      HOST_ISSUES=$((HOST_ISSUES + 1))

      if [ "$CHECK_ONLY" = false ]; then
        log_step "Installing dependencies (this may take a while)..."

        # Step 1: Clear existing environment and reinstall
        log_info "  Removing existing virtual environment..."
        run_poetry "$host" "env remove --all 2>/dev/null || true"

        log_info "  Running poetry install --sync..."
        INSTALL_OUTPUT=$(run_poetry "$host" "install --sync --no-interaction 2>&1" || echo "INSTALL_ERROR")

        if [[ "$INSTALL_OUTPUT" == *"INSTALL_ERROR"* ]]; then
          log_warning "Poetry install had issues, checking what's missing..."
        fi

        # Step 2: Verify pandas
        log_info "  Verifying pandas..."
        PANDAS_CHECK=$(run_poetry "$host" "run python -c 'import pandas; print(\"PANDAS_OK\")' 2>&1 || echo 'PANDAS_MISSING'")
        if [[ "$PANDAS_CHECK" != *"PANDAS_OK"* ]]; then
          log_warning "  Installing pandas via pip..."
          run_poetry "$host" "run pip install pandas 2>&1" || true
        fi

        # Step 3: Verify datasets (known issue - may not install via poetry)
        log_info "  Verifying datasets..."
        DATASETS_CHECK=$(run_poetry "$host" "run python -c 'import datasets; print(\"DATASETS_OK\")' 2>&1 || echo 'DATASETS_MISSING'")
        if [[ "$DATASETS_CHECK" != *"DATASETS_OK"* ]]; then
          log_warning "  Installing datasets via pip (poetry lock file issue workaround)..."
          run_poetry "$host" "run pip install datasets 2>&1" || true
        fi

        # Step 4: Verify openhands module
        log_info "  Verifying openhands..."
        OPENHANDS_CHECK=$(run_poetry "$host" "run python -c 'import openhands; print(\"OPENHANDS_OK\")' 2>&1 || echo 'OPENHANDS_MISSING'")
        if [[ "$OPENHANDS_CHECK" != *"OPENHANDS_OK"* ]]; then
          log_warning "  Re-running poetry install for openhands..."
          run_poetry "$host" "install --no-interaction 2>&1" || true
        fi

        # Step 5: Final comprehensive verification
        log_info "  Final verification..."
        FINAL_CHECK=$(run_poetry "$host" "run python -c '$CRITICAL_IMPORTS' 2>&1 || echo 'FINAL_FAILED'")

        if [[ "$FINAL_CHECK" == *"ALL_OK"* ]]; then
          log_success "All dependencies installed and verified"
          HOST_FIXED=$((HOST_FIXED + 1))
        else
          log_error "Some dependencies still missing after installation attempts"
          log_info "  Output: $FINAL_CHECK"

          # Try one more thing - install specific versions
          log_warning "  Attempting fallback installation..."
          run_poetry "$host" "run pip install 'datasets>=2.0.0' 'pandas>=1.0.0' 2>&1" || true

          FALLBACK_CHECK=$(run_poetry "$host" "run python -c '$CRITICAL_IMPORTS' 2>&1 || echo 'FALLBACK_FAILED'")
          if [[ "$FALLBACK_CHECK" == *"ALL_OK"* ]]; then
            log_success "Dependencies installed via fallback method"
            HOST_FIXED=$((HOST_FIXED + 1))
          else
            log_error "Failed to install all dependencies"
            log_info "  Please check manually: ssh -i $SSH_KEY ${SSH_USER}@${host}"
          fi
        fi
      else
        log_info "  [CHECK ONLY] Would install dependencies"
      fi
    fi
  fi

  # ============================================
  # CHECK 8: Docker
  # ============================================
  log_step "Checking Docker..."
  DOCKER_OK=$(ssh $SSH_OPTS "${SSH_USER}@${host}" "docker info &>/dev/null && echo 'OK' || echo 'FAILED'")

  if [ "$DOCKER_OK" = "OK" ]; then
    log_success "Docker is accessible"

    # Show Docker info
    DOCKER_VERSION=$(ssh $SSH_OPTS "${SSH_USER}@${host}" "docker --version 2>/dev/null | head -1")
    log_info "  $DOCKER_VERSION"

    # Check Docker disk usage
    DOCKER_DISK=$(ssh $SSH_OPTS "${SSH_USER}@${host}" "docker system df 2>/dev/null | head -5" || echo "")
    if [ -n "$DOCKER_DISK" ]; then
      log_info "  Docker disk usage:"
      echo "$DOCKER_DISK" | while read line; do log_info "    $line"; done
    fi
  else
    log_error "Docker not accessible"
    HOST_ISSUES=$((HOST_ISSUES + 1))

    if [ "$CHECK_ONLY" = false ]; then
      log_step "Attempting to fix Docker permissions..."
      ssh $SSH_OPTS "${SSH_USER}@${host}" "sudo usermod -aG docker \$USER 2>/dev/null || true"
      log_warning "Added user to docker group. May need to reconnect for changes to take effect."

      # Try starting docker service
      ssh $SSH_OPTS "${SSH_USER}@${host}" "sudo systemctl start docker 2>/dev/null || sudo service docker start 2>/dev/null || true"
    else
      log_info "  [CHECK ONLY] Would fix Docker permissions"
    fi
  fi

  # ============================================
  # CHECK 9: AWS CLI
  # ============================================
  log_step "Checking AWS CLI..."
  AWS_OK=$(ssh $SSH_OPTS "${SSH_USER}@${host}" "aws --version &>/dev/null && echo 'OK' || echo 'FAILED'")

  if [ "$AWS_OK" = "OK" ]; then
    log_success "AWS CLI installed"

    # Check if configured
    AWS_CONFIGURED=$(ssh $SSH_OPTS "${SSH_USER}@${host}" "aws sts get-caller-identity &>/dev/null && echo 'OK' || echo 'FAILED'")
    if [ "$AWS_CONFIGURED" = "OK" ]; then
      log_success "AWS credentials configured"
    else
      log_warning "AWS credentials not configured (needed for S3 access)"
      HOST_ISSUES=$((HOST_ISSUES + 1))

      if [ "$CHECK_ONLY" = false ]; then
        # Copy AWS credentials from local machine if they exist
        if [ -f "$HOME/.aws/credentials" ]; then
          log_step "Copying AWS credentials to $host..."
          ssh $SSH_OPTS "${SSH_USER}@${host}" "mkdir -p ~/.aws"
          scp $SCP_OPTS "$HOME/.aws/credentials" "${SSH_USER}@${host}:~/.aws/credentials"
          scp $SCP_OPTS "$HOME/.aws/config" "${SSH_USER}@${host}:~/.aws/config" 2>/dev/null || true
          log_success "AWS credentials copied"
          HOST_FIXED=$((HOST_FIXED + 1))
        else
          log_warning "No local AWS credentials to copy. Configure manually with 'aws configure'"
        fi
      else
        log_info "  [CHECK ONLY] Would copy AWS credentials"
      fi
    fi
  else
    log_error "AWS CLI not installed"
    HOST_ISSUES=$((HOST_ISSUES + 1))

    if [ "$CHECK_ONLY" = false ]; then
      log_step "Installing AWS CLI on $host..."
      ssh $SSH_OPTS "${SSH_USER}@${host}" "
        curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o 'awscliv2.zip' && \
        unzip -q awscliv2.zip && \
        sudo ./aws/install && \
        rm -rf aws awscliv2.zip
      "
      if [ $? -eq 0 ]; then
        log_success "AWS CLI installed"
        HOST_FIXED=$((HOST_FIXED + 1))
      else
        log_error "Failed to install AWS CLI"
      fi
    else
      log_info "  [CHECK ONLY] Would install AWS CLI"
    fi
  fi

  # ============================================
  # CHECK 10: Config.toml (API Keys)
  # ============================================
  log_step "Checking config.toml..."
  CONFIG_EXISTS=$(ssh $SSH_OPTS "${SSH_USER}@${host}" "[ -f '${REMOTE_VELORA_PATH}/config.toml' ] && echo 'YES' || echo 'NO'")

  if [ "$CONFIG_EXISTS" = "YES" ]; then
    log_success "config.toml exists"
  else
    log_warning "config.toml not found"
    HOST_ISSUES=$((HOST_ISSUES + 1))
  fi

  # Always sync config.toml to ensure API keys are up to date
  if [ "$CHECK_ONLY" = false ] && [ -f "$VELORA_ROOT/config.toml" ]; then
    log_step "Syncing config.toml (for API keys)..."
    scp $SCP_OPTS "$VELORA_ROOT/config.toml" "${SSH_USER}@${host}:${REMOTE_VELORA_PATH}/config.toml"
    log_success "config.toml synced"
    if [ "$CONFIG_EXISTS" = "NO" ]; then
      HOST_FIXED=$((HOST_FIXED + 1))
    fi
  fi

  # ============================================
  # CHECK 11: Disk Space
  # ============================================
  log_step "Checking disk space..."
  DISK_INFO=$(ssh $SSH_OPTS "${SSH_USER}@${host}" "df -h / | tail -1")
  DISK_AVAIL=$(echo "$DISK_INFO" | awk '{print $4}')
  DISK_PERCENT=$(echo "$DISK_INFO" | awk '{print $5}' | tr -d '%')

  if [ "$DISK_PERCENT" -lt 85 ]; then
    log_success "Disk space OK: $DISK_AVAIL available ($DISK_PERCENT% used)"
  elif [ "$DISK_PERCENT" -lt 95 ]; then
    log_warning "Disk space getting low: $DISK_AVAIL available ($DISK_PERCENT% used)"
    HOST_ISSUES=$((HOST_ISSUES + 1))

    if [ "$CHECK_ONLY" = false ]; then
      log_step "Cleaning up Docker to free space..."
      ssh $SSH_OPTS "${SSH_USER}@${host}" "docker system prune -f --volumes 2>/dev/null || true"
      # Also clean up old runtime images
      ssh $SSH_OPTS "${SSH_USER}@${host}" "docker images --filter 'reference=*runtime*' --filter 'dangling=false' -q 2>/dev/null | head -20 | xargs -r docker rmi 2>/dev/null || true"

      NEW_DISK_INFO=$(ssh $SSH_OPTS "${SSH_USER}@${host}" "df -h / | tail -1")
      NEW_DISK_AVAIL=$(echo "$NEW_DISK_INFO" | awk '{print $4}')
      log_success "Disk space after cleanup: $NEW_DISK_AVAIL available"
      HOST_FIXED=$((HOST_FIXED + 1))
    else
      log_info "  [CHECK ONLY] Would clean up Docker"
    fi
  else
    log_error "Disk space critically low: $DISK_AVAIL available ($DISK_PERCENT% used)"
    HOST_ISSUES=$((HOST_ISSUES + 1))

    if [ "$CHECK_ONLY" = false ]; then
      log_step "Aggressive cleanup to free space..."
      ssh $SSH_OPTS "${SSH_USER}@${host}" "docker system prune -af --volumes 2>/dev/null || true"

      NEW_DISK_INFO=$(ssh $SSH_OPTS "${SSH_USER}@${host}" "df -h / | tail -1")
      NEW_DISK_AVAIL=$(echo "$NEW_DISK_INFO" | awk '{print $4}')
      NEW_DISK_PERCENT=$(echo "$NEW_DISK_INFO" | awk '{print $5}' | tr -d '%')

      if [ "$NEW_DISK_PERCENT" -lt 90 ]; then
        log_success "Disk space after cleanup: $NEW_DISK_AVAIL available"
        HOST_FIXED=$((HOST_FIXED + 1))
      else
        log_error "Disk space still critically low after cleanup: $NEW_DISK_AVAIL available"
        log_info "  Please manually free space on $host"
      fi
    else
      log_info "  [CHECK ONLY] Would perform aggressive cleanup"
    fi
  fi

  # ============================================
  # CHECK 12: Docker Cleanup (pre-evaluation)
  # ============================================
  log_step "Performing pre-evaluation Docker cleanup..."

  if [ "$CHECK_ONLY" = false ]; then
    # Aggressive cleanup to ensure sufficient resources for evaluation
    CLEANUP_OUTPUT=$(ssh $SSH_OPTS "${SSH_USER}@${host}" "
      echo 'Stopping openhands containers...'
      docker ps -q --filter 'name=openhands' 2>/dev/null | xargs -r docker stop 2>/dev/null || true
      docker ps -q --filter 'name=sweb' 2>/dev/null | xargs -r docker stop 2>/dev/null || true

      echo 'Removing stopped containers...'
      docker container prune -f 2>/dev/null || true

      echo 'Removing OpenHands runtime images...'
      docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E '(ghcr.io/openhands/runtime|openhands-runtime)' | xargs -r docker rmi -f 2>/dev/null || true

      echo 'Removing dangling images...'
      docker image prune -f 2>/dev/null || true

      echo 'Removing unused volumes...'
      docker volume prune -f 2>/dev/null || true

      echo 'CLEANUP_DONE'
    " 2>&1)

    if [[ "$CLEANUP_OUTPUT" == *"CLEANUP_DONE"* ]]; then
      log_success "Docker cleanup complete"

      # Show post-cleanup Docker status
      DOCKER_DISK=$(ssh $SSH_OPTS "${SSH_USER}@${host}" "docker system df 2>/dev/null | head -3" || echo "")
      if [ -n "$DOCKER_DISK" ]; then
        log_info "  Docker disk usage after cleanup:"
        echo "$DOCKER_DISK" | while read line; do log_info "    $line"; done
      fi
    else
      log_warning "Docker cleanup may have had issues"
    fi
  else
    log_info "  [CHECK ONLY] Would perform Docker cleanup"
  fi

  # ============================================
  # CHECK 13: Test Full Import Chain
  # ============================================
  log_step "Testing full evaluation import chain..."

  # Source the environment file and test imports
  IMPORT_TEST=$(ssh $SSH_OPTS "${SSH_USER}@${host}" "
    source ${ENV_FILE} 2>/dev/null || true
    source ~/.bashrc 2>/dev/null || true
    export PATH=\$HOME/.local/bin:\$PATH
    cd ${REMOTE_VELORA_PATH}
    poetry run python -c '
import os
import sys

# Check git commit env var
git_commit = os.environ.get(\"OPENHANDS_GIT_COMMIT\", \"NOT_SET\")
print(f\"GIT_COMMIT: {git_commit[:8]}...\")

# Test critical imports
try:
    import pandas
    print(f\"pandas: {pandas.__version__}\")
except ImportError as e:
    print(f\"pandas: FAILED - {e}\")
    sys.exit(1)

try:
    import datasets
    print(f\"datasets: {datasets.__version__}\")
except ImportError as e:
    print(f\"datasets: FAILED - {e}\")
    sys.exit(1)

try:
    import openhands
    print(\"openhands: OK\")
except ImportError as e:
    print(f\"openhands: FAILED - {e}\")
    sys.exit(1)

print(\"IMPORT_TEST_PASSED\")
' 2>&1" || echo "IMPORT_TEST_FAILED")

  if [[ "$IMPORT_TEST" == *"IMPORT_TEST_PASSED"* ]]; then
    log_success "Full import chain verified"
    # Show version info
    echo "$IMPORT_TEST" | grep -E "(pandas|datasets|openhands|GIT_COMMIT):" | while read line; do
      log_info "    $line"
    done
  else
    log_error "Import chain test failed"
    log_info "  Output: $IMPORT_TEST"
    HOST_ISSUES=$((HOST_ISSUES + 1))
  fi

  # ============================================
  # HOST SUMMARY
  # ============================================
  echo ""
  if [ $HOST_ISSUES -eq 0 ]; then
    log_success "Host $host: READY (no issues)"
  elif [ "$CHECK_ONLY" = true ]; then
    log_warning "Host $host: $HOST_ISSUES issue(s) found (check-only mode)"
  else
    if [ $HOST_FIXED -ge $HOST_ISSUES ]; then
      log_success "Host $host: READY ($HOST_FIXED issue(s) fixed)"
    else
      log_warning "Host $host: $((HOST_ISSUES - HOST_FIXED)) issue(s) remaining"
    fi
  fi

  TOTAL_ISSUES=$((TOTAL_ISSUES + HOST_ISSUES))
  TOTAL_FIXED=$((TOTAL_FIXED + HOST_FIXED))
done

# ============================================
# FINAL SUMMARY
# ============================================
log_header "SETUP COMPLETE"

echo ""
echo "Hosts checked: $NUM_HOSTS"
echo "Total issues found: $TOTAL_ISSUES"
echo "Git commit tracked: ${LOCAL_GIT_COMMIT:0:8}..."

if [ "$CHECK_ONLY" = true ]; then
  echo "Mode: Check-only (no fixes applied)"
  if [ $TOTAL_ISSUES -eq 0 ]; then
    log_success "All hosts are ready for batch evaluation!"
    exit 0
  else
    log_warning "Run without --check-only to fix issues"
    exit 1
  fi
else
  echo "Issues fixed: $TOTAL_FIXED"
  echo "Issues remaining: $((TOTAL_ISSUES - TOTAL_FIXED))"

  if [ $((TOTAL_ISSUES - TOTAL_FIXED)) -le 0 ]; then
    log_success "All hosts are ready for batch evaluation!"
    echo ""
    echo "You can now run:"
    echo "  ./run_batch_eval.sh --model llm.gemini3 --dataset-dir ./dataset/ \\"
    echo "    --aws-hosts \"${AWS_HOSTS}\" --ssh-key $SSH_KEY"
    exit 0
  else
    log_error "Some issues could not be fixed automatically"
    echo ""
    echo "Please check the hosts manually and run setup again:"
    echo "  $0 --hosts \"${AWS_HOSTS}\" --ssh-key $SSH_KEY"
    exit 1
  fi
fi
