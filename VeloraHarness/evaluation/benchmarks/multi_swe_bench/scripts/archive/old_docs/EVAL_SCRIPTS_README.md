# Velora Evaluation Scripts

This directory contains xonsh scripts for running pass@k evaluations across multiple models and EC2 instances.

## Scripts

### 1. `velora_eval_runner.xsh` - Main Orchestrator

The primary script for running complete pass@k evaluations. Supports multi-model, multi-instance, and distributed execution.

**Basic Usage:**
```bash
# Single model, all instances, 8 runs (pass@8)
./velora_eval_runner.xsh --models gemini --runs 8

# Multiple models
./velora_eval_runner.xsh --models gemini,claude,gpt --runs 8

# Specific instances
./velora_eval_runner.xsh --models gemini --runs 8 --instances 1769880766122899,1769880766142606

# Range of instances
./velora_eval_runner.xsh --models gemini --runs 8 --instances 0:10

# Distributed across EC2 instances
./velora_eval_runner.xsh --models gemini --runs 8 --hosts aws-velora-1,aws-velora-2 --parallel
```

**All Options:**
```
--models, -m        Comma-separated models: gemini,claude,gpt (default: gemini)
--runs, -k          Number of runs per model per instance (default: 8)
--max-iterations    Max iterations for agent (default: 1000)
--timeout           Timeout in minutes per retry attempt (default: 10)
--retries           Number of retry attempts (default: 3)
--num-workers       Parallel workers per host (default: 1)
--instances, -i     Instance selection: all, ID, IDs, or range (default: all)
--dataset-dir       Path to dataset directory (default: ~/VeloraHarness/dataset)
--hosts             Comma-separated hostnames or IPs for distributed execution
--ssh-key           Path to SSH private key (for IP-based hosts)
--ssh-user          SSH username (default: ubuntu)
--parallel          Enable parallel execution across hosts
--distribution      Work distribution: by-model, by-data, matrix (default: by-data)
--reuse-container   Reuse container between runs (default: fresh container)
--output-dir, -o    Output directory (default: ./evaluation_results)
--config-toml       Path to config.toml with API keys
--resume            Resume from previous checkpoint
```

### 2. `run_eval.xsh` - Single Instance Evaluation

Runs trajectory generation and evaluation for a single instance. This is the xonsh equivalent of `run_full_eval_with_s3.sh`.

**Usage:**
```bash
./run_eval.xsh --model gemini --dataset ~/VeloraHarness/dataset/instances/1769880766122899.jsonl
./run_eval.xsh --model-config llm.gemini3 --dataset /path/to/instance.jsonl --max-iterations 500
```

**Options:**
```
--model, -m         Model name: gemini, claude, gpt
--model-config      LLM config name (overrides --model)
--dataset, -d       Path to dataset file (required)
--max-iterations    Max iterations for agent (default: 1000)
--num-workers       Number of parallel workers (default: 1)
--timeout           Evaluation timeout in seconds (default: 600)
--run-number        Run number for eval note (default: 1)
--fresh-container   Use fresh container (default: True)
--output-dir        Output directory
```

### 3. `ec2_setup.xsh` - EC2 Instance Setup

Sets up a fresh Ubuntu EC2 instance with all dependencies for evaluations.

**Usage:**
```bash
# Using SSH config hostname
./ec2_setup.xsh --host aws-velora-gemini

# Using IP address with key
./ec2_setup.xsh --host 54.123.45.67 --ssh-key ~/.ssh/my-key.pem --ssh-user ubuntu

# Force reinstall everything
./ec2_setup.xsh --host aws-velora-gemini --force
```

**Options:**
```
--host, -H          Hostname or IP address (required)
--ssh-key, -k       Path to SSH private key
--ssh-user, -u      SSH username (default: ubuntu)
--velora-path       Local path to VeloraHarness (default: .)
--config-toml       Path to config.toml (default: ./config.toml)
--skip-docker-image Skip Docker image loading
--force             Force reinstall even if already installed
```

## Workflow

### 1. Setup EC2 Instances (if needed)

```bash
# Setup single instance
./ec2_setup.xsh --host aws-velora-gemini

# Or setup multiple instances
for host in aws-velora-1 aws-velora-2 aws-velora-3; do
    ./ec2_setup.xsh --host $host &
done
wait
```

### 2. Run Evaluations

```bash
# Run overnight evaluation (all models, pass@8)
nohup ./velora_eval_runner.xsh \
    --models gemini,claude,gpt \
    --runs 8 \
    --max-iterations 1000 \
    --output-dir ~/evaluation_results \
    > evaluation.log 2>&1 &

# Distributed across 3 EC2 instances
nohup ./velora_eval_runner.xsh \
    --models gemini,claude,gpt \
    --runs 8 \
    --hosts aws-velora-1,aws-velora-2,aws-velora-3 \
    --parallel \
    --distribution by-data \
    --output-dir ~/evaluation_results \
    > evaluation.log 2>&1 &
```

### 3. Monitor Progress

```bash
# Watch the log
tail -f evaluation.log

# Check the master log
tail -f ~/evaluation_results/evaluation_master_*.log
```

### 4. Results

After completion, results are saved to:
```
evaluation_results/
├── evaluation_master_YYYYMMDD_HHMMSS.log    # Master log
├── evaluation_summary.json                    # Summary with pass@k metrics
├── host_results/                              # Downloaded tar files from each host
│   ├── results_aws-velora-1_*.tar.gz
│   └── results_aws-velora-2_*.tar.gz
└── ...
```

## Dataset Structure

The scripts expect individual instance files in `~/VeloraHarness/dataset/instances/`:

```
dataset/
├── instances/
│   ├── 1769880766092408.jsonl
│   ├── 1769880766094806.jsonl
│   └── ...
└── swelancer_final.jsonl   # Full dataset (optional)
```

Each `.jsonl` file contains a single JSON object with:
- `instance_id`: Unique identifier
- `repo`: Repository name
- `base_commit`: Git commit hash
- `problem_statement`: Issue description
- `FAIL_TO_PASS`: Tests that should pass after fix
- `test_command`: Command to run tests
- etc.

## Configuration

### config.toml

API keys and model configurations:
```toml
[llm.gemini3]
model = "gemini/gemini-3-pro-preview"
api_key = "YOUR_API_KEY"

[llm.claude]
model = "claude-opus-4-5-20251101"
api_key = "YOUR_API_KEY"

[llm.gpt]
model = "gpt-5.2-codex"
api_key = "YOUR_API_KEY"
```

### Environment Variables

```bash
export USE_SWELANCER_MONOLITH=true
export SWELANCER_MONOLITH_IMAGE="swelancer/unified:latest"
```

## Pass@k Calculation

The pass@k metric is calculated as:
```
pass@k = 1 - C(n-c, k) / C(n, k)
```
Where:
- n = number of runs
- c = number of successful runs
- k = k in pass@k

For pass@8 with 8 runs: if any run succeeds, pass@8 = 1.0

## Troubleshooting

### SSH Connection Issues
```bash
# Test connection
ssh -o ConnectTimeout=30 aws-velora-gemini 'echo "OK"'

# Check SSH config
cat ~/.ssh/config
```

### Docker Issues
```bash
# Check Docker is running
ssh aws-velora-gemini 'docker ps'

# Check Docker image exists
ssh aws-velora-gemini 'docker images | grep swelancer'
```

### Low Disk Space
```bash
# Clean up on remote
ssh aws-velora-gemini 'docker system prune -af'
```

### Resume Failed Run
```bash
# Resume from checkpoint
./velora_eval_runner.xsh --resume --output-dir ~/evaluation_results
```
