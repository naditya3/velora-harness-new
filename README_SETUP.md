# VeloraTrajectories - Multi-Model Setup Guide

This guide shows you how to generate trajectories for multiple LLMs using the Repomate CSV data.

## Overview

You have:
- **230,833 tasks** in the main CSV file
- **300 sample Docker images** for testing
- **VeloraHarness** framework for trajectory generation
- **4 target models**: Claude Opus 4.6, Kimi K2, Qwen3 Coder, GPT-5.2

## Quick Start

### 1. Set up API Keys

Edit `jaeger/VeloraHarness/config.toml` and add your API keys:

```bash
cd ~/VeloraTrajectories/jaeger/VeloraHarness
nano config.toml
```

Replace placeholders:
- `YOUR_ANTHROPIC_API_KEY_HERE` → Your Anthropic key (for Claude)
- `YOUR_MOONSHOT_API_KEY_HERE` → Your Moonshot key (for Kimi)
- `YOUR_QWEN_API_KEY_HERE` → Your Qwen/Alibaba Cloud key
- `YOUR_OPENAI_API_KEY_HERE` → Your OpenAI key (for GPT)
- `YOUR_GOOGLE_API_KEY_HERE` → Your Google key (for Gemini)

### 2. Convert CSV to JSONL

Convert the CSV data to VeloraHarness format:

```bash
# Convert first 100 tasks for testing
python convert_csv_to_jsonl.py \
    --csv "repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv" \
    --output jaeger/VeloraHarness/data/tasks.jsonl \
    --limit 100

# Or filter by language
python convert_csv_to_jsonl.py \
    --csv "repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv" \
    --output jaeger/VeloraHarness/data/tasks_go.jsonl \
    --language go \
    --limit 50
```

**Available languages**: `go`, `python`, `java`, `rust`, `cpp`, `javascript`

### 3. Download Docker Images

The Docker images need to be pulled from your registry:

```bash
# Example: Pull a specific image
docker pull vmvm-registry.fbinfra.net/repomate_image_activ_go_test/meroxa_cli:d45265fa27f5700a0a494a0f0597f340c485663c

# Tag for VeloraHarness (required format)
docker tag vmvm-registry.fbinfra.net/repomate_image_activ_go_test/meroxa_cli:d45265fa27f5700a0a494a0f0597f340c485663c \
    mswebench/meroxa_m_cli:pr-1841270650076475
```

**Note**: The image URIs are in `repomate_images_for_rubrics_300_sample.csv` and `image_mapping.csv` for AWS ECR locations.

### 4. Generate Trajectories

Run trajectory generation for all models:

```bash
chmod +x generate_trajectories.sh
./generate_trajectories.sh data/tasks.jsonl 10 outputs/
```

This will:
- Generate trajectories for 10 tasks using all 4 models
- Save outputs to `outputs/Claude_Opus_4.6/`, `outputs/Kimi_K2/`, etc.
- Log progress to `generation.log` in each directory

### 5. Evaluate Trajectories

After generation, evaluate the results:

```bash
chmod +x evaluate_trajectories.sh
./evaluate_trajectories.sh outputs data/tasks.jsonl mswebench
```

This will:
- Run tests against each model's generated patches
- Save evaluation results to `eval_output.jsonl`
- Display pass/fail statistics

## Directory Structure

```
VeloraTrajectories/
├── README_SETUP.md                    # This file
├── convert_csv_to_jsonl.py            # CSV converter script
├── generate_trajectories.sh           # Batch trajectory generation
├── evaluate_trajectories.sh           # Batch evaluation
│
├── repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv
├── repomate_images_for_rubrics_300_sample.csv
├── image_mapping.csv
│
├── jaeger/VeloraHarness/
│   ├── config.toml                    # ← Configure API keys here
│   ├── data/
│   │   └── tasks.jsonl                # Converted task dataset
│   └── ...
│
└── outputs/                           # Generated trajectories
    ├── Claude_Opus_4.6/
    │   ├── output.jsonl               # Raw trajectories
    │   ├── eval_output.jsonl          # Evaluation results
    │   └── generation.log
    ├── Kimi_K2/
    ├── Qwen3_Coder/
    └── GPT_5.2/
```

## Model Configurations

### Claude Opus 4.6
- **Model**: `claude-opus-4-6`
- **Config key**: `llm.opus`
- **Best for**: Complex reasoning, large codebases

### Kimi K2
- **Model**: `kimi-k2-0711-preview`
- **Config key**: `llm.kimi`
- **Best for**: Long context understanding

### Qwen3 Coder
- **Model**: `qwen3-coder`
- **Config key**: `llm.qwen`
- **Best for**: Optimized for code generation

### GPT-5.2
- **Model**: `gpt-5.2` (adjust when available)
- **Config key**: `llm.gpt`
- **Best for**: General-purpose coding

## Advanced Usage

### Run Specific Model Only

```bash
cd jaeger/VeloraHarness
export PYTHONPATH="$(pwd):$PYTHONPATH"

poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent-cls CodeActAgent \
    --llm-config llm.opus \
    --max-iterations 500 \
    --eval-num-workers 1 \
    --dataset data/tasks.jsonl \
    --split train \
    --eval-n-limit 10 \
    --eval-output-dir outputs/Claude_Opus_4.6/
```

### Filter Tasks by Language

```bash
# Generate Python tasks only
python convert_csv_to_jsonl.py \
    --csv "repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv" \
    --output data/tasks_python.jsonl \
    --language python \
    --limit 50

./generate_trajectories.sh data/tasks_python.jsonl 50 outputs/python/
```

### Parallel Execution

To run models in parallel (requires sufficient resources):

```bash
# Terminal 1
./generate_trajectories.sh data/tasks.jsonl 10 outputs/run1/ &

# Terminal 2
./generate_trajectories.sh data/tasks.jsonl 10 outputs/run2/ &

# Wait for both
wait
```

## Output Format

### Trajectory Output (`output.jsonl`)

Each line contains:
```json
{
  "instance_id": "1841270650076475",
  "test_result": {
    "git_patch": "diff --git a/...",
    "exit_code": 0
  },
  "history": [...],
  "metrics": {
    "cost": 0.05,
    "success": true
  }
}
```

### Evaluation Output (`eval_output.jsonl`)

Each line contains:
```json
{
  "instance_id": "1841270650076475",
  "resolved": true,
  "fail_to_pass_success": ["test1", "test2"],
  "fail_to_pass_failed": [],
  "pass_to_pass_success": ["test3"],
  "pass_to_pass_failed": []
}
```

## Troubleshooting

### Problem: CSV conversion fails

**Solution**: Check for malformed rows
```bash
# Test with single instance
python convert_csv_to_jsonl.py \
    --csv "repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv" \
    --output test.jsonl \
    --instance-id "1841270650076475"
```

### Problem: Docker image not found

**Solution**: Check image mapping and pull/tag correctly
```bash
# Find ECR URI
grep "meroxa_cli" image_mapping.csv

# Pull and tag
docker pull <ecr_uri>
docker tag <ecr_uri> mswebench/<image_name>
```

### Problem: API rate limits

**Solution**: Adjust retry settings in `config.toml`
```toml
[llm.opus]
num_retries = 12
retry_min_wait = 60
retry_max_wait = 300
```

## Cost Estimation

Approximate costs per 100 tasks (500 iterations max):

- **Claude Opus 4.6**: ~$150-200
- **GPT-5.2**: ~$100-150 (estimate)
- **Kimi K2**: ~$50-80
- **Qwen3 Coder**: ~$30-50

**Recommendation**: Start with 10-20 tasks to calibrate costs.

## Next Steps

1. ✅ Set up API keys in `config.toml`
2. ✅ Convert CSV to JSONL (start with 10-50 tasks)
3. ✅ Pull/tag required Docker images
4. ✅ Run trajectory generation
5. ✅ Evaluate results
6. 📊 Analyze and compare model performance

## Support

For issues or questions:
- Check VeloraHarness README: `jaeger/VeloraHarness/README.md`
- Review logs in `outputs/<model>/generation.log`
- Check Docker status: `docker ps -a`
