#!/bin/bash
# Deploy VeloraHarness to EC2
# Usage: ./deploy_to_ec2.sh <EC2_HOST> [EC2_PATH]
# Example: ./deploy_to_ec2.sh ubuntu@ip-172-31-39-88 ~/Velora_SWE_Harness

set -e

EC2_HOST="${1:-ubuntu@ip-172-31-39-88}"
EC2_PATH="${2:-~/Velora_SWE_Harness}"

echo "============================================"
echo "Deploying VeloraHarness to EC2"
echo "============================================"
echo "EC2_HOST: $EC2_HOST"
echo "EC2_PATH: $EC2_PATH"
echo ""

# Create remote directory structure
echo "Creating remote directory structure..."
ssh "$EC2_HOST" "mkdir -p $EC2_PATH"

# Sync VeloraHarness (excluding large/unnecessary files)
echo "Syncing VeloraHarness..."
rsync -avz --progress \
    --exclude='.git' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='.venv' \
    --exclude='node_modules' \
    --exclude='*.tar' \
    --exclude='*.tar.gz' \
    --exclude='workspace/' \
    --exclude='evaluation_outputs/' \
    --exclude='.mypy_cache' \
    --exclude='.pytest_cache' \
    VeloraHarness/ "$EC2_HOST:$EC2_PATH/VeloraHarness/"

echo ""
echo "============================================"
echo "Deployment complete!"
echo "============================================"
echo ""
echo "Next steps on EC2:"
echo "  ssh $EC2_HOST"
echo "  cd $EC2_PATH/VeloraHarness"
echo ""
echo "  # Install poetry (if not installed)"
echo "  curl -sSL https://install.python-poetry.org | python3 -"
echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
echo ""
echo "  # Install dependencies"
echo "  poetry install"
echo ""
echo "  # Run the evaluation"
echo "  ./evaluation/benchmarks/multi_swe_bench/scripts/swe-hard/run_full_eval_swe.sh \\"
echo "    llm.gemini_codex \\"
echo "    data/erusev__parsedown.pr_685.jsonl \\"
echo "    1 300 1"
echo ""

