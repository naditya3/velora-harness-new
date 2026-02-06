# Multi-Model Trajectory Generation Guide

## Overview

Automated trajectory generation system for running multiple LLM models on the repomate dataset. This system processes 75 data samples from `repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv`.

## Models Supported

1. **Claude Opus 4.6** - Anthropic's most capable model
2. **GPT-5.2** - OpenAI's latest (using gpt-4o)
3. **Kimi K2.5** - Moonshot's advanced model
4. **Qwen 3 Coder Plus** - Specialized coding model

## Quick Start

### 1. Prerequisites

Ensure all API keys are configured in [config.toml](config.toml):

```toml
[llm.opus]
api_key = "YOUR_ANTHROPIC_API_KEY_HERE"

[llm.gpt]
api_key = "YOUR_OPENAI_API_KEY_HERE"

[llm.kimi]
api_key = "YOUR_MOONSHOT_API_KEY_HERE"

[llm.qwen]
api_key = "YOUR_OPENROUTER_API_KEY_HERE"
```

### 2. Run Trajectory Generation

```bash
cd /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness
./run_multi_model_trajectories.sh
```

### 3. Choose Execution Mode

The script will prompt you to select:

- **Sequential Mode (1)**: Run models one after another
  - Safer, lower resource usage
  - Takes longer (4× the time of one model)
  - Best for limited resources

- **Parallel Mode (2)**: Run all models simultaneously
  - Faster completion
  - High resource usage (CPU, memory, GPU)
  - Best for powerful machines

- **Custom Mode (3)**: Select specific models
  - Run only the models you need
  - Flexible for testing

## File Structure

```
VeloraHarness/
├── run_multi_model_trajectories.sh    # Main automation script
├── scripts/
│   └── prepare_repomate_dataset.py    # CSV to JSONL converter
├── data/
│   └── repomate_75_samples.jsonl      # Generated dataset (75 samples)
├── config.toml                         # Model configurations
└── evaluation/
    └── evaluation_outputs/
        └── outputs/
            └── data__repomate_75_samples.jsonl-train/
                └── CodeActAgent/
                    ├── repomate_75_multimodel_opus*/
                    ├── repomate_75_multimodel_gpt*/
                    ├── repomate_75_multimodel_kimi*/
                    └── repomate_75_multimodel_qwen*/
```

## Manual Operations

### Convert CSV to JSONL Only

```bash
python3 scripts/prepare_repomate_dataset.py 75
```

This creates `data/repomate_75_samples.jsonl` with 75 samples.

### Run Single Model

```bash
# Set environment
cd /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness
export PYTHONPATH=$(pwd):$PYTHONPATH
export USE_INSTANCE_IMAGE=false

# Run for specific model
sg docker -c "python3 evaluation/benchmarks/swe_bench/run_infer.py \
    --agent-cls CodeActAgent \
    --llm-config opus \
    --max-iterations 500 \
    --eval-num-workers 1 \
    --dataset data/repomate_75_samples.jsonl \
    --split train \
    --eval-note repomate_75_opus"
```

Replace `opus` with `gpt`, `kimi`, or `qwen` for other models.

### View Results

```bash
# List all output directories
ls -lh evaluation/evaluation_outputs/outputs/data__repomate_75_samples.jsonl-train/CodeActAgent/

# Check specific model output
ls -lh evaluation/evaluation_outputs/outputs/data__repomate_75_samples.jsonl-train/CodeActAgent/repomate_75_multimodel_opus*/

# View trajectory file
cat evaluation/evaluation_outputs/outputs/data__repomate_75_samples.jsonl-train/CodeActAgent/repomate_75_multimodel_opus*/output.jsonl
```

## Configuration Details

### Model Configurations (config.toml)

Each model has specific settings:

```toml
[llm.opus]
model = "claude-opus-4-6"
api_key = "YOUR_KEY"
base_url = "https://api.anthropic.com"
temperature = 1.0
timeout = 600
num_retries = 8

[llm.gpt]
model = "gpt-4o"
api_key = "YOUR_KEY"
base_url = "https://api.openai.com/v1"
temperature = 1.0
timeout = 600
num_retries = 8

[llm.kimi]
model = "moonshot-v1-128k"
api_key = "YOUR_KEY"
base_url = "https://api.moonshot.cn/v1"
temperature = 1.0
timeout = 600
num_retries = 12

[llm.qwen]
model = "qwen/qwen-2.5-coder-32b-instruct"
api_key = "YOUR_KEY"
base_url = "https://openrouter.ai/api/v1"
temperature = 1.0
timeout = 600
num_retries = 8
```

### Execution Parameters

- **Max Iterations**: 500 (can be adjusted in script)
- **Agent**: CodeActAgent
- **Workers**: 1 (conservative for stability)
- **Dataset**: 75 samples
- **Split**: train

## Troubleshooting

### Dataset Not Created

```bash
# Manually run converter
python3 scripts/prepare_repomate_dataset.py 75
```

### API Key Issues

Check your config.toml and ensure all API keys are set correctly:

```bash
grep "api_key" config.toml
```

### Docker Permission Errors

```bash
# Add user to docker group (if not already done)
sudo usermod -aG docker $USER
newgrp docker
```

### Check Logs

```bash
# Logs are stored in timestamped directory
ls -ltr ../../outputs/multimodel_logs_*/

# View specific model log
tail -f ../../outputs/multimodel_logs_YYYYMMDD_HHMMSS/opus_trajectory.log
```

## Performance Estimates

### Sequential Mode (Estimated)
- **Per Model**: ~2-4 hours (depending on model speed)
- **Total Time**: ~8-16 hours for all 4 models

### Parallel Mode (Estimated)
- **Total Time**: ~2-4 hours (all models running simultaneously)
- **Resource Usage**: High CPU, memory, potentially GPU

### Resource Requirements

**Sequential Mode:**
- CPU: 2-4 cores
- RAM: 8-16 GB
- Disk: 10 GB free

**Parallel Mode:**
- CPU: 8-16 cores
- RAM: 32-64 GB
- Disk: 20 GB free

## Output Format

Each model generates an `output.jsonl` file with trajectory data:

```json
{
  "instance_id": "1841270650076475",
  "model_name": "claude-opus-4-6",
  "trajectory": [...],
  "test_results": {...},
  "metadata": {...}
}
```

## Advanced Usage

### Custom Sample Count

```bash
# Generate 100 samples instead of 75
python3 scripts/prepare_repomate_dataset.py 100

# Update dataset path in run_multi_model_trajectories.sh
# Then run the script
```

### Change Max Iterations

Edit `run_multi_model_trajectories.sh`:

```bash
MAX_ITER=1000  # Change from 500 to 1000
```

### Add New Model

1. Add configuration to `config.toml`:
```toml
[llm.newmodel]
model = "model-name"
api_key = "YOUR_KEY"
...
```

2. Edit `run_multi_model_trajectories.sh`:
```bash
MODELS=("opus" "gpt" "kimi" "qwen" "newmodel")
MODEL_NAMES=(
    "Claude Opus 4.6"
    "GPT-5.2"
    "Kimi K2.5"
    "Qwen 3 Coder Plus"
    "New Model"
)
```

## Support

For issues or questions:
- Check logs in `../../outputs/multimodel_logs_*/`
- Review output in `evaluation/evaluation_outputs/outputs/`
- Verify API keys in `config.toml`

---

**Created**: 2026-02-06
**Author**: Expert Coder with 36 years experience
**Version**: 1.0
