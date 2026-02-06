# Gemini Trajectory Generation Guide

This guide walks you through generating Gemini trajectories from the CSV dataset.

## Prerequisites

1. **Gemini API Key**: Get from [Google AI Studio](https://makersuite.google.com/app/apikey)
2. **Python 3.11+**: Already installed ✓
3. **Dataset**: CSV file converted to JSONL ✓

## Quick Start

### 1. Set up API Key

```bash
export GEMINI_API_KEY="your_api_key_here"
```

Or add to ~/.bashrc for persistence:
```bash
echo 'export GEMINI_API_KEY="your_api_key_here"' >> ~/.bashrc
source ~/.bashrc
```

### 2. Run Trajectory Generation

```bash
cd /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness
./run_gemini_trajectories.sh
```

Or run manually:
```bash
cd /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness
export PYTHONPATH=/home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness:$PYTHONPATH

python3 evaluation/benchmarks/swe_bench/run_infer.py \
  --agent-cls CodeActAgent \
  --llm-config gemini/gemini-2.0-flash-exp \
  --max-iterations 50 \
  --eval-num-workers 1 \
  --dataset data/gemini_trajectories_50.jsonl \
  --split train \
  --eval-note "gemini_trajectories_50"
```

## Current Setup

- **Dataset**: `data/gemini_trajectories_50.jsonl` (50 instances)
- **Model**: `gemini-2.0-flash-exp`
- **Agent**: `CodeActAgent`
- **Max Iterations**: 50
- **Output**: `../../outputs/gemini_trajectories_50/`

## Scaling Up

### Generate More Instances

To convert more instances from the CSV:

```bash
cd /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness

# Convert 100 instances
python3 evaluation/benchmarks/client_tasks/csv_to_jsonl_large.py \
  --csv "../../repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv" \
  --output data/gemini_trajectories_100.jsonl \
  --limit 100

# Convert 500 instances
python3 evaluation/benchmarks/client_tasks/csv_to_jsonl_large.py \
  --csv "../../repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv" \
  --output data/gemini_trajectories_500.jsonl \
  --limit 500

# Skip first 100 and get next 100
python3 evaluation/benchmarks/client_tasks/csv_to_jsonl_large.py \
  --csv "../../repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv" \
  --output data/gemini_trajectories_100_200.jsonl \
  --skip 100 \
  --limit 100
```

### Use Different Models

Edit the script and change the `MODEL` variable:
- `gemini/gemini-2.0-flash-exp` - Fast experimental (default)
- `gemini/gemini-2.0-pro-exp` - More capable experimental
- `gemini/gemini-1.5-pro` - Stable production

## Output Structure

```
outputs/
└── gemini_trajectories_50/
    └── data__gemini_trajectories_50.jsonl-train/
        └── CodeActAgent/
            └── gemini-2.0-flash-exp_maxiter_50/
                ├── output.jsonl          # Generated trajectories
                ├── metadata.json         # Run metadata
                ├── logs/                 # Execution logs
                └── llm_completions/      # LLM API calls
```

## Monitoring Progress

Watch the log file:
```bash
tail -f ../../outputs/gemini_trajectories_50/data__gemini_trajectories_50.jsonl-train/CodeActAgent/*/output.jsonl
```

## Troubleshooting

### API Key Not Found
```
Error: GEMINI_API_KEY not set
```
**Solution**: Export the environment variable:
```bash
export GEMINI_API_KEY="your_api_key_here"
```

### Module Not Found: openhands
```
ModuleNotFoundError: No module named 'openhands'
```
**Solution**: Set PYTHONPATH:
```bash
export PYTHONPATH=/home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness:$PYTHONPATH
```

### Docker Issues
If you encounter Docker-related errors, ensure Docker is running:
```bash
sudo systemctl status docker
```

## Files Created

1. **CSV Converter**: `evaluation/benchmarks/client_tasks/csv_to_jsonl_large.py`
2. **Run Script**: `run_gemini_trajectories.sh`
3. **Dataset**: `data/gemini_trajectories_50.jsonl`
4. **Environment Example**: `.env.example`
5. **This Guide**: `/home/ec2-user/VeloraTrajectories/GEMINI_TRAJECTORY_GUIDE.md`

## Next Steps

1. Set your GEMINI_API_KEY environment variable
2. Run `./run_gemini_trajectories.sh`
3. Monitor progress in the outputs directory
4. Analyze generated trajectories

For questions or issues, refer to the OpenHands documentation or check the logs.
