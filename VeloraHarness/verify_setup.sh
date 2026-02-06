#!/usr/bin/env bash
set -e

################################################################################
# Setup Verification Script
# Checks if everything is ready for multi-model trajectory generation
################################################################################

cd /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness

echo "================================================================================"
echo "  Setup Verification for Multi-Model Trajectory Generation"
echo "================================================================================"
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

ERRORS=0
WARNINGS=0

# Function to check status
check_pass() {
    echo -e "${GREEN}✓${NC} $1"
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
    ((ERRORS++))
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
    ((WARNINGS++))
}

# Check 1: Dataset exists
echo "Checking dataset..."
if [ -f "data/repomate_75_samples.jsonl" ]; then
    LINES=$(wc -l < data/repomate_75_samples.jsonl)
    if [ "$LINES" -eq 75 ]; then
        check_pass "Dataset exists with 75 samples"
    else
        check_warn "Dataset exists but has $LINES samples (expected 75)"
    fi
else
    check_fail "Dataset not found at data/repomate_75_samples.jsonl"
    echo "  Run: python3 scripts/prepare_repomate_dataset.py 75"
fi
echo ""

# Check 2: Config file
echo "Checking configuration..."
if [ -f "config.toml" ]; then
    check_pass "config.toml exists"

    # Check for API keys
    if grep -q "YOUR_ANTHROPIC_API_KEY_HERE" config.toml; then
        check_warn "Claude Opus API key not configured (still placeholder)"
    else
        check_pass "Claude Opus API key configured"
    fi

    if grep -q "sk-proj-" config.toml || grep -q "sk-" config.toml; then
        check_pass "GPT API key appears configured"
    else
        check_warn "GPT API key may not be configured"
    fi

    if grep -q "YOUR_MOONSHOT_API_KEY_HERE" config.toml; then
        check_warn "Kimi API key not configured (still placeholder)"
    else
        check_pass "Kimi API key configured"
    fi

    if grep -q "YOUR_OPENROUTER_API_KEY_HERE" config.toml; then
        check_warn "Qwen API key not configured (still placeholder)"
    else
        check_pass "Qwen API key configured"
    fi
else
    check_fail "config.toml not found"
    echo "  Copy from: cp config.toml.example config.toml"
fi
echo ""

# Check 3: Scripts exist and are executable
echo "Checking scripts..."
if [ -f "run_multi_model_trajectories.sh" ] && [ -x "run_multi_model_trajectories.sh" ]; then
    check_pass "Main script exists and is executable"
else
    check_fail "Main script not found or not executable"
    echo "  Run: chmod +x run_multi_model_trajectories.sh"
fi

if [ -f "scripts/prepare_repomate_dataset.py" ] && [ -x "scripts/prepare_repomate_dataset.py" ]; then
    check_pass "Dataset preparation script exists and is executable"
else
    check_fail "Dataset prep script not found or not executable"
fi
echo ""

# Check 4: Docker access
echo "Checking Docker..."
if command -v docker &> /dev/null; then
    check_pass "Docker command found"

    if docker ps &> /dev/null; then
        check_pass "Docker is accessible (no permission issues)"
    else
        check_warn "Docker command exists but may have permission issues"
        echo "  Try: sudo usermod -aG docker \$USER && newgrp docker"
    fi
else
    check_fail "Docker not found"
fi
echo ""

# Check 5: Python
echo "Checking Python..."
if command -v python3 &> /dev/null; then
    PYTHON_VERSION=$(python3 --version 2>&1 | awk '{print $2}')
    check_pass "Python 3 found (version: $PYTHON_VERSION)"
else
    check_fail "Python 3 not found"
fi
echo ""

# Check 6: Source CSV
echo "Checking source data..."
SOURCE_CSV="/home/ec2-user/VeloraTrajectories/repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv"
if [ -f "$SOURCE_CSV" ]; then
    CSV_LINES=$(wc -l < "$SOURCE_CSV")
    check_pass "Source CSV found with $CSV_LINES lines"
else
    check_warn "Source CSV not found (dataset already created, this is OK)"
fi
echo ""

# Check 7: Disk space
echo "Checking disk space..."
AVAILABLE=$(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//')
if [ "$AVAILABLE" -gt 20 ]; then
    check_pass "Sufficient disk space (${AVAILABLE}GB available)"
elif [ "$AVAILABLE" -gt 10 ]; then
    check_warn "Limited disk space (${AVAILABLE}GB available, recommend 20GB+)"
else
    check_fail "Insufficient disk space (${AVAILABLE}GB available, need at least 10GB)"
fi
echo ""

# Summary
echo "================================================================================"
echo "  Verification Summary"
echo "================================================================================"

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}✓ All checks passed! You're ready to run trajectory generation.${NC}"
    echo ""
    echo "To start, run:"
    echo "  ./run_multi_model_trajectories.sh"
elif [ $ERRORS -eq 0 ]; then
    echo -e "${YELLOW}⚠ Setup complete with $WARNINGS warning(s).${NC}"
    echo "  You can proceed, but review warnings above."
    echo ""
    echo "To start, run:"
    echo "  ./run_multi_model_trajectories.sh"
else
    echo -e "${RED}✗ Setup incomplete: $ERRORS error(s), $WARNINGS warning(s)${NC}"
    echo "  Please fix errors above before proceeding."
    exit 1
fi

echo "================================================================================"
