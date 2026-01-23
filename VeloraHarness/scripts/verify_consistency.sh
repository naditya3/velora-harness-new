#!/bin/bash
# verify_consistency.sh - Verify code consistency between local and AWS instances
#
# Usage: ./scripts/verify_consistency.sh [instance1] [instance2] ...
# Example: ./scripts/verify_consistency.sh eval1 eval2 lancer1

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_ok() { echo -e "${GREEN}✓${NC} $1"; }
log_err() { echo -e "${RED}✗${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }

# Expected checksums (as of 2026-01-23)
declare -A EXPECTED_CHECKSUMS=(
  ["evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh"]="fe08d93ed67b76c21e59b9d84e07ba36"
  ["evaluation/benchmarks/multi_swe_bench/scripts/eval_pilot2_standardized.py"]="c71b963ae19398e900681ec2340da445"
  ["openhands/runtime/builder/docker.py"]="c719fdafa6102198c8068f530846cac3"
  ["openhands/runtime/utils/runtime_templates/Dockerfile.j2"]="6edc931ce32b967dd50dc91d7f08551f"
)

# Change to repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

echo "============================================"
echo "VeloraHarness Consistency Verification"
echo "============================================"
echo ""

# ============================================
# Check Local Files
# ============================================
echo "=== Local Repository Verification ==="
echo "Location: $REPO_ROOT"
echo ""

local_all_ok=true

for file in "${!EXPECTED_CHECKSUMS[@]}"; do
  if [ -f "$file" ]; then
    actual=$(md5 -r "$file" 2>/dev/null | cut -d' ' -f1)
    expected="${EXPECTED_CHECKSUMS[$file]}"

    if [ "$actual" = "$expected" ]; then
      log_ok "$file"
    else
      log_err "$file - CHECKSUM MISMATCH"
      echo "     Expected: $expected"
      echo "     Actual:   $actual"
      local_all_ok=false
    fi
  else
    log_err "$file - NOT FOUND"
    local_all_ok=false
  fi
done

echo ""
if [ "$local_all_ok" = true ]; then
  log_ok "Local repository: All files verified"
else
  log_err "Local repository: Some files have issues"
  exit 1
fi

# ============================================
# Check Instance Files
# ============================================
if [ $# -eq 0 ]; then
  echo ""
  log_warn "No instances specified - skipping instance verification"
  log_warn "Usage: $0 eval1 eval2 lancer1 ..."
  exit 0
fi

for INSTANCE in "$@"; do
  echo ""
  echo "=========================================="
  echo "Instance: aws-instance-$INSTANCE"
  echo "=========================================="

  # Check if instance is reachable
  if ! ssh -o ConnectTimeout=5 "aws-instance-$INSTANCE" "echo ''" 2>/dev/null; then
    log_err "Cannot connect to aws-instance-$INSTANCE"
    continue
  fi

  instance_ok=true

  # Check each file
  for file in "${!EXPECTED_CHECKSUMS[@]}"; do
    expected="${EXPECTED_CHECKSUMS[$file]}"

    # Get checksum from instance
    actual=$(ssh "aws-instance-$INSTANCE" "cd ~/SWETEs7/OpenHands && md5sum '$file' 2>/dev/null | cut -d' ' -f1" 2>/dev/null)

    if [ -z "$actual" ]; then
      log_err "$file - NOT FOUND on instance"
      instance_ok=false
    elif [ "$actual" = "$expected" ]; then
      log_ok "$file"
    else
      log_err "$file - CHECKSUM MISMATCH"
      echo "     Expected: $expected"
      echo "     Actual:   $actual"
      instance_ok=false
    fi
  done

  echo ""
  if [ "$instance_ok" = true ]; then
    log_ok "aws-instance-$INSTANCE: All files verified"
  else
    log_err "aws-instance-$INSTANCE: Deployment needed"
  fi
done

echo ""
echo "============================================"
echo "Verification Complete"
echo "============================================"
