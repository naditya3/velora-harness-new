# VeloraHarness Evaluation Scripts

This directory contains scripts for running pass@k evaluations across multiple models and EC2 instances.

## Quick Start

```bash
# Single model, 8 runs per instance
./rct.sh --models gemini --runs 8

# Using config file
./rct.sh --config rct_config.toml

# Specific instances
./rct.sh --models gemini --runs 8 --instances 1769880766122899
```

---

## Available Scripts

| Script | Purpose | When to Use |
|--------|---------|-------------|
| **`rct.sh`** | Primary pass@k evaluation runner | Main script for all evaluations |
| `run_full_eval_with_s3.sh` | Single instance evaluation | Called internally by rct.sh |
| `run_batch_master.sh` | TOML-based batch orchestration | For complex multi-worker setups |
| `setup_remote_hosts.sh` | EC2 instance setup | One-time setup of new servers |

### Supporting Files

| File | Purpose |
|------|---------|
| `rct_config.toml` | Example config for rct.sh |
| `batch_config.toml` | Example config for run_batch_master.sh |
| `eval_pilot2_standardized.py` | Core evaluation logic |

---

## rct.sh - Primary Evaluation Script

### Features

- Multi-model evaluation (gemini, claude, gpt)
- Pass@k evaluation with configurable k
- TOML configuration file support
- CLI parameter support (overrides TOML)
- Multi-EC2 distributed execution
- Automatic EC2 setup for fresh instances
- Comprehensive logging and progress tracking
- Result aggregation and summary generation

### Usage

```bash
# CLI only
./rct.sh --models gemini --runs 8 --max-iterations 1000

# TOML config
./rct.sh --config rct_config.toml

# Config + CLI overrides
./rct.sh --config rct_config.toml --models gemini,claude --runs 4

# Distributed execution
./rct.sh --models gemini --runs 8 --hosts aws-velora-1,aws-velora-2 --parallel

# Dry run (show what would execute)
./rct.sh --models gemini --runs 8 --dry-run
```

### Command-Line Options

| Option | Default | Description |
|--------|---------|-------------|
| `--config PATH` | - | Load settings from TOML config file |
| `-m, --models` | gemini | Models to evaluate (gemini,claude,gpt) |
| `-k, --runs` | 8 | Number of runs per instance (k in pass@k) |
| `--max-iterations` | 1000 | Max agent iterations |
| `--timeout` | 45 | Timeout per attempt (minutes) |
| `--retries` | 3 | Retry attempts per run |
| `-i, --instances` | all | Instance filter (all, ID, or 0:10) |
| `--hosts` | localhost | Comma-separated hostnames for distribution |
| `--parallel` | false | Enable parallel across hosts |
| `-o, --output-dir` | ./evaluation/evaluation_outputs | Output directory |
| `--dry-run` | false | Show what would run without executing |
| `-h, --help` | - | Show help message |

---

## run_full_eval_with_s3.sh - Core Evaluator

This script runs evaluation for a single instance. It is called internally by `rct.sh` but can be used directly.

### Usage

```bash
./run_full_eval_with_s3.sh <model_config> <dataset_file> <eval_limit> <max_iterations> <num_workers>
```

### Example

```bash
./run_full_eval_with_s3.sh llm.gemini3 ~/VeloraHarness/dataset/instances/1769880766122899.jsonl 1 1000 1
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `USE_SWELANCER_MONOLITH` | true | Use monolith Docker image |
| `SWELANCER_MONOLITH_IMAGE` | swelancer/unified:latest | Docker image to use |
| `N_RUNS` | 1 | Number of runs |
| `RUN_NUMBER_OFFSET` | 0 | Offset for run numbering (for pass@k) |

---

## run_batch_master.sh - Batch Orchestration

For complex batch evaluations with TOML configuration.

### Usage

```bash
./run_batch_master.sh --config batch_config.toml
./run_batch_master.sh --config batch_config.toml --dry-run
./run_batch_master.sh --config batch_config.toml --local-only
```

---

## Output Structure

```
evaluation/evaluation_outputs/
├── evaluation_master_YYYYMMDD_HHMMSS.log    # Master log
├── evaluation_summary.json                   # Results summary
├── evaluation_results_YYYYMMDD_HHMMSS.tar.gz # Archive for download
└── outputs/
    └── <dataset>-train/
        └── CodeActAgent/
            └── <model>_maxiter_<N>_v1.1.0-no-hint-run_<K>/
                ├── output.jsonl           # Trajectory
                ├── metadata.json          # Run metadata
                └── eval_outputs/
                    └── <instance_id>/
                        ├── patch.diff     # Model's patch
                        ├── test_output.txt # Test results
                        ├── run_instance.log # Evaluation log
                        └── report.json    # Results
```

---

## Troubleshooting

### Docker image not found

```bash
# Load from S3
aws s3 cp s3://rfp-coding-q1/Images/RCT/Expensify_App-unified_x86_monolith.tar /tmp/
docker load < /tmp/Expensify_App-unified_x86_monolith.tar
docker tag <loaded_image> swelancer/unified:latest
```

### Evaluation times out

Increase timeout:
```bash
./rct.sh --models gemini --runs 8 --timeout 60
```

### Test fails with "username not found"

This indicates webpack compilation failed. Check:
1. Correct node_modules cache for the commit
2. Docker image has commit-specific caches

### View evaluation logs

```bash
# Master log
tail -f evaluation/evaluation_outputs/evaluation_master_*.log

# Instance log
cat evaluation/evaluation_outputs/outputs/*/<model>_*/eval_outputs/<instance_id>/run_instance.log
```

---

## Model Configuration

Models are configured in `config.toml`:

```toml
[llm.gemini3]
model = "gemini-3-pro-preview"
api_key = "..."

[llm.claude]
model = "claude-sonnet-4-20250514"
api_key = "..."

[llm.gpt]
model = "gpt-5.2-codex"
api_key = "..."
```

---

## See Also

- [TOML Config Example](./rct_config.toml) - Sample configuration
- [Batch Config Example](./batch_config.toml) - Batch configuration
- [Troubleshooting Guide](../../docs/TROUBLESHOOTING_GUIDE.md) - Detailed troubleshooting
