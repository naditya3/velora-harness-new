#!/usr/bin/env bash
set -eo pipefail

# Navigate to the correct directory
cd /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness

# Configuration
DATASET="data/gemini_trajectories_50.jsonl"
SPLIT="train"
MODEL="gemini/gemini-2.0-flash-exp"
AGENT="CodeActAgent"
MAX_ITER=50
NUM_WORKERS=1

echo "========================================="
echo "Gemini Trajectory Generation"
echo "========================================="
echo "Dataset: $DATASET"
echo "Model: $MODEL"
echo "Agent: $AGENT"
echo "Max Iterations: $MAX_ITER"
echo "========================================="
echo ""

# Check if Gemini API key is set
if [ -z "$GEMINI_API_KEY" ] && [ -z "$GOOGLE_API_KEY" ]; then
  echo "WARNING: GEMINI_API_KEY or GOOGLE_API_KEY not set"
  echo "Please set one of these environment variables:"
  echo "  export GEMINI_API_KEY=your_api_key"
  echo "  export GOOGLE_API_KEY=your_api_key"
  echo ""
  read -p "Do you want to continue anyway? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

# Set PYTHONPATH
export PYTHONPATH=/home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness:$PYTHONPATH

# Run the inference
python3 evaluation/benchmarks/swe_bench/run_infer.py \
  --agent-cls "$AGENT" \
  --llm-config "$MODEL" \
  --max-iterations "$MAX_ITER" \
  --eval-num-workers "$NUM_WORKERS" \
  --dataset "$DATASET" \
  --split "$SPLIT" \
  --eval-note "gemini_trajectories_50"

echo ""
echo "========================================="
echo "Trajectory generation complete!"
echo "Output location:"
echo "  ../../outputs/gemini_trajectories_50/data__gemini_trajectories_50.jsonl-train/CodeActAgent/"
echo "========================================="
