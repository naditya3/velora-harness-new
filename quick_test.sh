#!/bin/bash
#
# Quick Test Script - Verify VeloraTrajectories Setup
#
# This script tests the setup with a minimal example
#

set -e

echo "========================================="
echo "VeloraTrajectories - Quick Test"
echo "========================================="
echo

# Step 1: Convert sample CSV data
echo "Step 1: Converting CSV to JSONL (5 tasks)..."
python3 convert_csv_to_jsonl.py \
    --csv "repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv" \
    --output jaeger/VeloraHarness/data/test_tasks.jsonl \
    --limit 5

echo "✓ Converted tasks saved to: jaeger/VeloraHarness/data/test_tasks.jsonl"
echo

# Step 2: Show sample task
echo "Step 2: Sample task preview..."
echo "----------------------------------------"
head -1 jaeger/VeloraHarness/data/test_tasks.jsonl | python3 -m json.tool | head -20
echo "... (truncated)"
echo "----------------------------------------"
echo

# Step 3: Check config
echo "Step 3: Checking config.toml..."
cd jaeger/VeloraHarness

if grep -q "YOUR_ANTHROPIC_API_KEY_HERE" config.toml; then
    echo "⚠ Warning: API keys not configured!"
    echo "  Please edit jaeger/VeloraHarness/config.toml and add your keys"
    echo
fi

if ! grep -q "YOUR_ANTHROPIC_API_KEY_HERE" config.toml; then
    echo "✓ API keys appear to be configured"
fi
echo

# Step 4: Check dependencies
echo "Step 4: Checking dependencies..."
if command -v poetry &> /dev/null; then
    echo "✓ Poetry installed"
else
    echo "⚠ Poetry not found - install with: pip install poetry"
fi

if command -v docker &> /dev/null; then
    echo "✓ Docker installed"
else
    echo "⚠ Docker not found - required for evaluation"
fi
echo

# Step 5: Environment check
echo "Step 5: Environment variables..."
echo "PYTHONPATH: ${PYTHONPATH:-not set}"
echo "DOCKER_BUILDKIT: ${DOCKER_BUILDKIT:-not set (will be set to 0)}"
echo

echo "========================================="
echo "Setup Test Complete!"
echo "========================================="
echo
echo "Next steps:"
echo "1. Configure API keys in: jaeger/VeloraHarness/config.toml"
echo "2. Test single trajectory:"
echo "   cd jaeger/VeloraHarness"
echo "   export PYTHONPATH=\$(pwd):\$PYTHONPATH"
echo "   poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \\"
echo "       --agent-cls CodeActAgent \\"
echo "       --llm-config llm.opus \\"
echo "       --max-iterations 50 \\"
echo "       --dataset data/test_tasks.jsonl \\"
echo "       --eval-n-limit 1"
echo
echo "3. Run full batch: ./generate_trajectories.sh data/test_tasks.jsonl 5 outputs/"
