#!/bin/bash
# Deploy VeloraHarness to velora_2 EC2 instance
# Usage:
#   Dry-run: ./deploy_to_velora2.sh --dry-run
#   Deploy:  ./deploy_to_velora2.sh

set -e

# Configuration
SSH_ALIAS="velora_2"
EC2_PATH="/home/ubuntu/velora"
DATASET_PATH="VeloraHarness/data/Shopify/1769848885641113.jsonl"
LLM_CONFIG="llm.gemini_codex"

# Parse arguments
DRY_RUN=false
if [[ "$1" == "--dry-run" ]] || [[ "$1" == "-n" ]]; then
  DRY_RUN=true
  echo "============================================"
  echo "DRY-RUN MODE (no files will be modified)"
  echo "============================================"
  echo ""
fi

echo "============================================"
echo "Deploying VeloraHarness to velora_2"
echo "============================================"
echo "SSH Alias: $SSH_ALIAS"
echo "EC2 Path: $EC2_PATH"
echo "Dataset: $DATASET_PATH"
echo "LLM Config: $LLM_CONFIG"
echo ""

# ============================================
# STEP 1: VERIFY SSH CONNECTION
# ============================================
echo "============================================"
echo "STEP 1: Verifying SSH connection"
echo "============================================"

if ssh "$SSH_ALIAS" "echo 'SSH connection successful' && whoami && pwd" 2>&1; then
  echo "✓ SSH connection verified"
else
  echo "✗ ERROR: Cannot connect to $SSH_ALIAS"
  echo "Please check your SSH configuration"
  exit 1
fi
echo ""

# ============================================
# STEP 2: CHECK PREREQUISITES
# ============================================
echo "============================================"
echo "STEP 2: Checking prerequisites on velora_2"
echo "============================================"

# Check Docker
echo -n "Checking Docker... "
if ssh "$SSH_ALIAS" "docker --version" >/dev/null 2>&1; then
  DOCKER_VERSION=$(ssh "$SSH_ALIAS" "docker --version")
  echo "✓ $DOCKER_VERSION"
else
  echo "✗ ERROR: Docker not installed"
  exit 1
fi

# Check Poetry
echo -n "Checking Poetry... "
if ssh "$SSH_ALIAS" "poetry --version" >/dev/null 2>&1; then
  POETRY_VERSION=$(ssh "$SSH_ALIAS" "poetry --version")
  echo "✓ $POETRY_VERSION"
else
  echo "✗ ERROR: Poetry not installed"
  exit 1
fi

# Check AWS CLI and S3 access
echo -n "Checking AWS CLI and S3 access... "
if ssh "$SSH_ALIAS" "aws s3 ls s3://rfp-coding-q1/Images/ 2>&1 | head -1" >/dev/null 2>&1; then
  echo "✓ AWS CLI configured with S3 access"
else
  echo "✗ ERROR: Cannot access s3://rfp-coding-q1/"
  exit 1
fi

# Check disk space
echo -n "Checking disk space... "
DISK_AVAIL=$(ssh "$SSH_ALIAS" "df -h / | tail -1 | awk '{print \$4}'")
echo "✓ Available: $DISK_AVAIL"

echo ""

# ============================================
# STEP 3: CREATE DIRECTORY STRUCTURE
# ============================================
echo "============================================"
echo "STEP 3: Creating directory structure"
echo "============================================"

if [ "$DRY_RUN" = true ]; then
  echo "[DRY-RUN] Would create: $EC2_PATH/VeloraHarness"
else
  ssh "$SSH_ALIAS" "mkdir -p $EC2_PATH"
  echo "✓ Created $EC2_PATH"
fi
echo ""

# ============================================
# STEP 4: SYNC VELORAHARNESS
# ============================================
echo "============================================"
echo "STEP 4: Syncing VeloraHarness"
echo "============================================"

RSYNC_FLAGS="-avz --progress"
if [ "$DRY_RUN" = true ]; then
  RSYNC_FLAGS="$RSYNC_FLAGS --dry-run"
fi

rsync $RSYNC_FLAGS \
    --exclude='.git' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='.venv' \
    --exclude='node_modules' \
    --exclude='*.tar' \
    --exclude='*.tar.gz' \
    --exclude='workspace/' \
    --exclude='evaluation_outputs/' \
    --exclude='harness/evaluation_results/' \
    --exclude='.mypy_cache' \
    --exclude='.pytest_cache' \
    --exclude='.DS_Store' \
    VeloraHarness/ "$SSH_ALIAS:$EC2_PATH/VeloraHarness/"

if [ "$DRY_RUN" = true ]; then
  echo ""
  echo "[DRY-RUN] Files would be synced to $SSH_ALIAS:$EC2_PATH/VeloraHarness/"
else
  echo ""
  echo "✓ VeloraHarness synced successfully"
fi
echo ""

# ============================================
# STEP 5: VERIFY DEPLOYMENT
# ============================================
echo "============================================"
echo "STEP 5: Verifying deployment"
echo "============================================"

if [ "$DRY_RUN" = true ]; then
  echo "[DRY-RUN] Would verify files on remote"
else
  echo "Checking remote directory structure..."
  ssh "$SSH_ALIAS" "ls -la $EC2_PATH/VeloraHarness/" | head -20

  echo ""
  echo "Verifying key files exist..."
  ssh "$SSH_ALIAS" "test -f $EC2_PATH/VeloraHarness/config.toml && echo '✓ config.toml'" || echo "✗ config.toml missing"
  ssh "$SSH_ALIAS" "test -f $EC2_PATH/$DATASET_PATH && echo '✓ Dataset file'" || echo "✗ Dataset file missing"
  ssh "$SSH_ALIAS" "test -f $EC2_PATH/VeloraHarness/evaluation/benchmarks/multi_swe_bench/scripts/swe-hard/run_full_eval_swe.sh && echo '✓ run_full_eval_swe.sh'" || echo "✗ Script missing"
  ssh "$SSH_ALIAS" "test -f $EC2_PATH/VeloraHarness/evaluation/benchmarks/multi_swe_bench/scripts/swe-hard/eval_standardized_swe.py && echo '✓ eval_standardized_swe.py'" || echo "✗ Eval script missing"
fi
echo ""

# ============================================
# SUMMARY
# ============================================
echo ""
echo "============================================"
if [ "$DRY_RUN" = true ]; then
  echo "DRY-RUN COMPLETE"
else
  echo "DEPLOYMENT COMPLETE"
fi
echo "============================================"
echo ""

if [ "$DRY_RUN" = false ]; then
  echo "Next steps on velora_2:"
  echo ""
  echo "  ssh $SSH_ALIAS"
  echo "  cd $EC2_PATH/VeloraHarness"
  echo ""
  echo "  # Initialize git (required by OpenHands)"
  echo "  git init"
  echo "  git add ."
  echo "  git commit -m 'Initial commit'"
  echo ""
  echo "  # Install Poetry dependencies"
  echo "  poetry install"
  echo ""
  echo "  # Install additional dependencies"
  echo "  poetry run pip install datasets"
  echo ""
  echo "  # Run the evaluation"
  echo "  cd evaluation/benchmarks/multi_swe_bench/scripts"
  echo "  ./run_full_eval_swe.sh \\"
  echo "    $LLM_CONFIG \\"
  echo "    ../../../../$DATASET_PATH \\"
  echo "    1 300 1"
  echo ""
else
  echo "Dry-run completed successfully!"
  echo ""
  echo "To proceed with actual deployment, run:"
  echo "  ./deploy_to_velora2.sh"
  echo ""
fi
