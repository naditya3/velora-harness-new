# Multi-SWE-Bench Evaluation Scripts - Complete Guide

This document provides comprehensive documentation for the Velora Multi-SWE-Bench evaluation pipeline, including single instance evaluation, batch evaluation across multiple AWS instances, and remote host setup.

---

## Table of Contents

1. [Overview](#overview)
2. [Quick Start](#quick-start)
3. [Scripts Summary](#scripts-summary)
4. [Setup Remote Hosts: `setup_remote_hosts.sh`](#setup-remote-hosts-setup_remote_hostssh)
5. [Single Instance Evaluation: `run_full_eval_with_s3.sh`](#single-instance-evaluation-run_full_eval_with_s3sh)
6. [Batch Evaluation: `run_batch_eval.sh`](#batch-evaluation-run_batch_evalsh)
7. [Docker Management](#docker-management)
8. [Complete Examples](#complete-examples)
9. [Troubleshooting](#troubleshooting)
10. [Output Files Reference](#output-files-reference)

---

## Overview

The Multi-SWE-Bench evaluation pipeline consists of three main scripts:

| Script | Purpose | When to Use |
|--------|---------|-------------|
| `setup_remote_hosts.sh` | Setup and verify AWS hosts | Before running distributed batch evaluation |
| `run_full_eval_with_s3.sh` | Single instance evaluation | Testing single instances or local runs |
| `run_batch_eval.sh` | Batch evaluation orchestrator | Running multiple instances locally or distributed |

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         EVALUATION PIPELINE                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────┐                                                     │
│  │ setup_remote_hosts  │  ← Run FIRST to prepare AWS instances              │
│  │        .sh          │                                                     │
│  └──────────┬──────────┘                                                     │
│             │                                                                │
│             ▼                                                                │
│  ┌─────────────────────┐     ┌─────────────────────────────────────────┐   │
│  │   run_batch_eval    │────▶│  Distributes to multiple AWS hosts      │   │
│  │        .sh          │     │                                         │   │
│  └──────────┬──────────┘     │  ┌─────────┐  ┌─────────┐  ┌─────────┐ │   │
│             │                │  │ Host 0  │  │ Host 1  │  │ Host N  │ │   │
│             │                │  │(Worker) │  │(Worker) │  │(Worker) │ │   │
│             │                │  └────┬────┘  └────┬────┘  └────┬────┘ │   │
│             │                │       │            │            │      │   │
│             ▼                │       ▼            ▼            ▼      │   │
│  ┌─────────────────────┐     │  ┌─────────────────────────────────┐   │   │
│  │ run_full_eval_with  │◀────┴──│   run_full_eval_with_s3.sh     │   │   │
│  │      _s3.sh         │        │   (runs on each host)          │   │   │
│  └─────────────────────┘        └─────────────────────────────────┘   │   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Quick Start

### Option 1: Local Evaluation (Single Machine)

```bash
cd /home/ubuntu/Velora_SWE_Harness-4/VeloraHarness

# Run single instance
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh \
  llm.gemini3 ./dataset/518290527943513.jsonl

# Run all instances in dataset folder (sequential)
./evaluation/benchmarks/multi_swe_bench/scripts/run_batch_eval.sh \
  --model llm.gemini3 \
  --dataset-dir ./dataset/ \
  --max-iter 30
```

### Option 2: Distributed Evaluation (Multiple AWS Instances)

```bash
cd /home/ubuntu/Velora_SWE_Harness-4/VeloraHarness

# Step 1: Setup remote hosts (run once)
./evaluation/benchmarks/multi_swe_bench/scripts/setup_remote_hosts.sh \
  --hosts "34.230.26.157,54.89.56.184" \
  --ssh-key ~/.ssh/velora-us.pem

# Step 2: Run batch evaluation
./evaluation/benchmarks/multi_swe_bench/scripts/run_batch_eval.sh \
  --model llm.gemini3 \
  --dataset-dir ./dataset/ \
  --max-iter 30 \
  --aws-hosts "34.230.26.157,54.89.56.184" \
  --ssh-key ~/.ssh/velora-us.pem
```

---

## Scripts Summary

### File Locations

```
VeloraHarness/
├── evaluation/
│   └── benchmarks/
│       └── multi_swe_bench/
│           └── scripts/
│               ├── setup_remote_hosts.sh      # Setup AWS hosts
│               ├── run_full_eval_with_s3.sh   # Single instance eval
│               ├── run_batch_eval.sh          # Batch orchestrator
│               ├── eval_pilot2_standardized.py # Patch evaluator
│               └── README.md                   # This file
├── dataset/
│   ├── 518290527943513.jsonl
│   ├── 538997559166630.jsonl
│   └── ...
├── config.toml                                 # LLM API configurations
└── evaluation/
    ├── batch_logs/                            # Batch run logs
    └── evaluation_outputs/                    # Evaluation results
```

---

## Setup Remote Hosts: `setup_remote_hosts.sh`

This script prepares AWS instances for distributed evaluation by checking and fixing common issues.

### What It Does

| Step | Check | Auto-Fix Action |
|------|-------|-----------------|
| 1 | SSH connectivity | ❌ Manual fix required |
| 2 | VeloraHarness directory | ✅ Syncs from local machine |
| 3 | Evaluation scripts | ✅ Synced with VeloraHarness |
| 4 | Poetry installation | ✅ Installs Poetry automatically |
| 5 | Poetry dependencies | ✅ Runs `poetry install` |
| 6 | Docker access | ✅ Adds user to docker group |
| 7 | AWS CLI installation | ✅ Installs AWS CLI |
| 8 | AWS credentials | ✅ Copies from local ~/.aws/ |
| 9 | config.toml (API keys) | ✅ Syncs from local |
| 10 | Disk space | ✅ Cleans Docker if low |

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `--hosts` | **Yes** | - | Comma-separated list of AWS hostnames/IPs |
| `--ssh-key` | **Yes** | - | Path to SSH private key (.pem file) |
| `--ssh-user` | No | `ubuntu` | SSH username |
| `--ssh-port` | No | `22` | SSH port |
| `--remote-path` | No | `/home/ubuntu/Velora_SWE_Harness-4/VeloraHarness` | VeloraHarness path on remote |
| `--check-only` | No | `false` | Only check, don't fix issues |
| `--force-sync` | No | `false` | Force re-sync VeloraHarness even if exists |
| `--skip-poetry-install` | No | `false` | Skip `poetry install` step |

### Usage Examples

```bash
# Basic setup - check and fix all issues
./evaluation/benchmarks/multi_swe_bench/scripts/setup_remote_hosts.sh \
  --hosts "34.230.26.157,54.89.56.184" \
  --ssh-key ~/.ssh/velora-us.pem

# Check only - see what issues exist without fixing
./evaluation/benchmarks/multi_swe_bench/scripts/setup_remote_hosts.sh \
  --hosts "34.230.26.157,54.89.56.184" \
  --ssh-key ~/.ssh/velora-us.pem \
  --check-only

# Force complete re-sync
./evaluation/benchmarks/multi_swe_bench/scripts/setup_remote_hosts.sh \
  --hosts "34.230.26.157,54.89.56.184" \
  --ssh-key ~/.ssh/velora-us.pem \
  --force-sync

# Setup with custom SSH user and port
./evaluation/benchmarks/multi_swe_bench/scripts/setup_remote_hosts.sh \
  --hosts "host1.aws.com,host2.aws.com" \
  --ssh-key ~/.ssh/my-key.pem \
  --ssh-user ec2-user \
  --ssh-port 2222
```

### Sample Output

```
============================================
REMOTE HOST SETUP
============================================
Hosts: 34.230.26.157 54.89.56.184
SSH User: ubuntu
Remote Path: /home/ubuntu/Velora_SWE_Harness-4/VeloraHarness
Check Only: false
Force Sync: false

============================================
HOST 1/2: 34.230.26.157
============================================
  -->  Checking SSH connectivity...
[SUCCESS] SSH connection OK
  -->  Checking VeloraHarness installation...
[WARNING] VeloraHarness not found
  -->  Syncing VeloraHarness to 34.230.26.157...
[SUCCESS] VeloraHarness synced
  -->  Checking Poetry installation...
[SUCCESS] Poetry installed: Poetry (version 1.8.2)
  -->  Checking Docker...
[SUCCESS] Docker is accessible
  -->  Checking AWS CLI...
[SUCCESS] AWS CLI installed
[SUCCESS] AWS credentials configured
  -->  Checking config.toml...
[SUCCESS] config.toml exists
  -->  Checking disk space...
[SUCCESS] Disk space OK: 45G available (35% used)

[SUCCESS] Host 34.230.26.157: READY (1 issue(s) fixed)

============================================
SETUP COMPLETE
============================================

Hosts checked: 2
Total issues found: 2
Issues fixed: 2
Issues remaining: 0
[SUCCESS] All hosts are ready for batch evaluation!

You can now run:
  ./run_batch_eval.sh --model llm.gemini3 --dataset-dir ./dataset/ \
    --aws-hosts "34.230.26.157,54.89.56.184" --ssh-key ~/.ssh/velora-us.pem
```

---

## Single Instance Evaluation: `run_full_eval_with_s3.sh`

This script performs end-to-end evaluation of a single instance.

### Pipeline Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        run_full_eval_with_s3.sh                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  PHASE 1: SETUP                                                              │
│  ├── Set environment variables (DOCKER_BUILDKIT=0, PYTHONPATH, etc.)        │
│  ├── Parse arguments (MODEL, DATASET, EVAL_LIMIT, MAX_ITER, etc.)           │
│  └── Validate inputs                                                         │
│                                                                              │
│  PHASE 2: DOCKER IMAGE PREPARATION                                           │
│  ├── Extract instance_id, image_storage_uri from dataset JSON               │
│  ├── Download Docker image from S3                                           │
│  ├── Load image: docker load < image.tar                                    │
│  ├── Delete .tar file (save disk space)                                     │
│  ├── Create OpenHands-compatible tags:                                       │
│  │   ├── TAG1: mswebench/sweb.eval.x86_64.<instance_id>:latest              │
│  │   └── TAG2: mswebench/<repo>:pr-<instance_id>                            │
│  ├── Check for tmux, install if missing (required by OpenHands)             │
│  └── Clean up old runtime images                                            │
│                                                                              │
│  PHASE 3: TRAJECTORY GENERATION                                              │
│  ├── Run: poetry run python run_infer.py                                    │
│  │   ├── --agent-cls CodeActAgent                                            │
│  │   ├── --llm-config $MODEL_CONFIG                                          │
│  │   ├── --max-iterations $MAX_ITER                                          │
│  │   └── ... other options                                                   │
│  └── Output: output.jsonl, metadata.json, llm_completions/                  │
│                                                                              │
│  PHASE 4: PATCH EVALUATION                                                   │
│  ├── Run: python3 eval_pilot2_standardized.py                               │
│  │   ├── --trajectory-file output.jsonl                                      │
│  │   ├── --dataset-file dataset.jsonl                                        │
│  │   ├── --docker-image $TAG1                                                │
│  │   └── --timeout 600                                                       │
│  └── Output: eval_pilot2_output.jsonl                                       │
│                                                                              │
│  PHASE 5: REPORT GENERATION                                                  │
│  ├── Create report.json (OpenHands format)                                  │
│  ├── Save test_output.txt                                                   │
│  ├── Extract patch.diff                                                     │
│  └── Create run_instance.log                                                │
│                                                                              │
│  PHASE 6: POST-RUN CLEANUP                                                   │
│  ├── Remove TAG1 and TAG2 images                                            │
│  ├── Remove original source image                                           │
│  ├── Remove OpenHands runtime images                                        │
│  └── Prune dangling images                                                  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Parameters

| Parameter | Position | Required | Default | Description |
|-----------|----------|----------|---------|-------------|
| `MODEL_CONFIG` | 1 | **Yes** | - | LLM configuration from config.toml (e.g., `llm.gemini3`, `llm.gpt`, `llm.claude`) |
| `DATASET` | 2 | **Yes** | - | Path to instance .jsonl file |
| `EVAL_LIMIT` | 3 | No | `1` | Number of evaluation iterations |
| `MAX_ITER` | 4 | No | `30` | Maximum agent iterations (LLM calls) |
| `NUM_WORKERS` | 5 | No | `1` | Parallel workers for trajectory |
| `AGENT` | 6 | No | `CodeActAgent` | OpenHands agent class |

### Environment Variables Set

| Variable | Value | Purpose |
|----------|-------|---------|
| `DOCKER_BUILDKIT` | `0` | **Critical**: Prevents buildx failures |
| `EVAL_DOCKER_IMAGE_PREFIX` | `mswebench` | Docker image prefix |
| `USE_INSTANCE_IMAGE` | `true` | Use instance-specific images |
| `LANGUAGE` | `python` | Task language |
| `RUN_WITH_BROWSING` | `false` | Disable browser interactions |
| `USE_HINT_TEXT` | `false` | Disable hints for fair eval |
| `PYTHONPATH` | `$(pwd):$PYTHONPATH` | Module resolution |

### Usage Examples

```bash
cd /home/ubuntu/Velora_SWE_Harness-4/VeloraHarness

# Basic usage - minimum required parameters
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh \
  llm.gemini3 \
  ./dataset/518290527943513.jsonl

# With custom max iterations (for more complex tasks)
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh \
  llm.gemini3 \
  ./dataset/518290527943513.jsonl \
  1 \
  50

# Full parameters
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh \
  llm.gpt \
  ./dataset/518290527943513.jsonl \
  1 \
  100 \
  1 \
  CodeActAgent

# With logging to file
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh \
  llm.gemini3 \
  ./dataset/518290527943513.jsonl \
  2>&1 | tee evaluation_run.log
```

### Tmux Fix Function

Many Docker images lack tmux (required by OpenHands). The script automatically installs it:

```bash
fix_docker_image_with_tmux() {
  # 1. Create temporary container
  CONTAINER_ID=$(docker run -d --entrypoint /bin/bash "$SOURCE_IMAGE" -c "sleep 300")

  # 2. Fix apt sources for Ubuntu Jammy
  docker exec "$CONTAINER_ID" bash -c '
    cat > /etc/apt/sources.list << "EOF"
deb http://archive.ubuntu.com/ubuntu/ jammy main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ jammy-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ jammy-security main restricted universe multiverse
EOF
    apt-get update && apt-get install -y tmux
  '

  # 3. Commit as new image
  docker commit "$CONTAINER_ID" "$TARGET_TAG"

  # 4. Cleanup
  docker stop "$CONTAINER_ID" && docker rm "$CONTAINER_ID"
}
```

---

## Batch Evaluation: `run_batch_eval.sh`

This script orchestrates evaluation of multiple instances, supporting both local and distributed execution.

### Execution Modes

#### Local Mode (Sequential)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           LOCAL MODE                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  For each instance in dataset-dir:                                           │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │ 1. Pre-run cleanup: docker system prune -f --volumes                  │ │
│  │                                                                        │ │
│  │ 2. Run: run_full_eval_with_s3.sh MODEL INSTANCE LIMIT ITER WORKERS    │ │
│  │                                                                        │ │
│  │ 3. Track progress in progress.json                                    │ │
│  │                                                                        │ │
│  │ 4. Post-run cleanup: docker system prune -f                           │ │
│  │                                                                        │ │
│  │ 5. Log to: batch_logs/TIMESTAMP/<instance_id>.log                     │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              │                                               │
│                              ▼                                               │
│                    [Next Instance]                                           │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Distributed Mode (Parallel)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DISTRIBUTED MODE                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  1. VERIFY: Pre-flight check all remote hosts                               │
│                                                                              │
│  2. DIVIDE: Round-robin distribution of instances                           │
│                                                                              │
│     Given: 10 instances, 3 hosts                                            │
│                                                                              │
│     Instance 0  → Host 0    Instance 5  → Host 2                            │
│     Instance 1  → Host 1    Instance 6  → Host 0                            │
│     Instance 2  → Host 2    Instance 7  → Host 1                            │
│     Instance 3  → Host 0    Instance 8  → Host 2                            │
│     Instance 4  → Host 1    Instance 9  → Host 0                            │
│                                                                              │
│     Result:                                                                  │
│       Host 0: 4 instances (0, 3, 6, 9)                                      │
│       Host 1: 3 instances (1, 4, 7)                                         │
│       Host 2: 3 instances (2, 5, 8)                                         │
│                                                                              │
│  3. SYNC: Copy assigned .jsonl files to each host                           │
│                                                                              │
│  4. LAUNCH: Start worker script on each host (parallel SSH)                 │
│                                                                              │
│     ┌─────────────┐   ┌─────────────┐   ┌─────────────┐                    │
│     │   Host 0    │   │   Host 1    │   │   Host 2    │                    │
│     │  (Worker)   │   │  (Worker)   │   │  (Worker)   │                    │
│     ├─────────────┤   ├─────────────┤   ├─────────────┤                    │
│     │ Instance 0  │   │ Instance 1  │   │ Instance 2  │                    │
│     │ Instance 3  │   │ Instance 4  │   │ Instance 5  │                    │
│     │ Instance 6  │   │ Instance 7  │   │ Instance 8  │                    │
│     │ Instance 9  │   │             │   │             │                    │
│     └─────────────┘   └─────────────┘   └─────────────┘                    │
│           │                 │                 │                             │
│           └────────────┬────┴────────────────┘                             │
│                        ▼                                                    │
│  5. MONITOR: Poll for worker completion every 30 seconds                    │
│                                                                              │
│  6. COLLECT: Fetch logs and outputs from all hosts                          │
│                                                                              │
│  7. AGGREGATE: Create summary.json with combined results                    │
│                                                                              │
│  8. CLEANUP: Remove temp files from remote hosts                            │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Parameters

#### Required Parameters

| Parameter | Short | Description |
|-----------|-------|-------------|
| `--model` | `-m` | LLM configuration from config.toml |
| `--dataset-dir` | `-d` | Directory containing .jsonl instance files |

#### Evaluation Parameters

| Parameter | Short | Default | Description |
|-----------|-------|---------|-------------|
| `--max-iter` | `-i` | `30` | Maximum agent iterations per instance |
| `--eval-limit` | `-l` | `1` | Evaluation limit per instance |
| `--workers` | `-w` | `1` | Workers within each evaluation |
| `--agent` | `-a` | `CodeActAgent` | OpenHands agent class |

#### AWS Distributed Mode Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--aws-hosts` | - | Comma-separated AWS hostnames/IPs (enables distributed mode) |
| `--ssh-key` | - | SSH private key path (**required** with `--aws-hosts`) |
| `--ssh-user` | `ubuntu` | SSH username |
| `--ssh-port` | `22` | SSH port |
| `--remote-path` | `/home/ubuntu/Velora_SWE_Harness-4/VeloraHarness` | VeloraHarness path on remote |

#### Control Parameters

| Parameter | Description |
|-----------|-------------|
| `--dry-run` | Preview distribution without executing |
| `--retry-failed` | Only retry previously failed instances |
| `--resume-from ID` | Resume from specific instance ID |
| `--help` | Show help message |

### Usage Examples

```bash
cd /home/ubuntu/Velora_SWE_Harness-4/VeloraHarness

# Local mode - run all instances sequentially
./evaluation/benchmarks/multi_swe_bench/scripts/run_batch_eval.sh \
  --model llm.gemini3 \
  --dataset-dir ./dataset/ \
  --max-iter 30

# Distributed mode - run on 2 AWS instances in parallel
./evaluation/benchmarks/multi_swe_bench/scripts/run_batch_eval.sh \
  --model llm.gemini3 \
  --dataset-dir ./dataset/ \
  --max-iter 30 \
  --aws-hosts "34.230.26.157,54.89.56.184" \
  --ssh-key ~/.ssh/velora-us.pem

# Dry run - preview distribution without executing
./evaluation/benchmarks/multi_swe_bench/scripts/run_batch_eval.sh \
  --model llm.gemini3 \
  --dataset-dir ./dataset/ \
  --aws-hosts "host1,host2,host3" \
  --dry-run

# Resume from specific instance
./evaluation/benchmarks/multi_swe_bench/scripts/run_batch_eval.sh \
  --model llm.gemini3 \
  --dataset-dir ./dataset/ \
  --resume-from "538997559166630"

# With all options
./evaluation/benchmarks/multi_swe_bench/scripts/run_batch_eval.sh \
  --model llm.gpt \
  --dataset-dir ./dataset/ \
  --max-iter 100 \
  --eval-limit 1 \
  --workers 1 \
  --agent CodeActAgent \
  --aws-hosts "host1.aws.com,host2.aws.com,host3.aws.com" \
  --ssh-key ~/.ssh/my-key.pem \
  --ssh-user ec2-user \
  --ssh-port 22 \
  --remote-path /opt/velora/VeloraHarness
```

### Pre-Flight Checks (Distributed Mode)

Before syncing files, the script verifies each host:

1. **SSH Connectivity** - Can connect via SSH
2. **VeloraHarness Directory** - Installation exists
3. **Evaluation Script** - `run_full_eval_with_s3.sh` exists
4. **Poetry** - Poetry is installed and in PATH
5. **Docker** - Docker daemon is accessible

If any check fails, the script aborts with instructions to run `setup_remote_hosts.sh`.

---

## Docker Management

### Cleanup Strategy

| Phase | Action | Command |
|-------|--------|---------|
| Pre-run (batch) | Remove volumes | `docker system prune -f --volumes` |
| Pre-run (single) | Remove old runtime images | `docker rmi ghcr.io/openhands/runtime*` |
| Post-eval | Remove TAG1, TAG2 | `docker rmi -f $TAG1 $TAG2` |
| Post-eval | Remove source image | `docker rmi -f $IMAGE_URI` |
| Post-eval | Remove runtime images | `docker rmi ghcr.io/openhands/runtime*` |
| Post-eval | Prune dangling | `docker image prune -f` |
| Post-run (batch) | General prune | `docker system prune -f` |

### Docker Images Created

| Image Type | Naming Pattern | Lifecycle |
|------------|----------------|-----------|
| Source Image | `<registry>/<repo>:<commit>` | Downloaded from S3, cleaned after eval |
| TAG1 | `mswebench/sweb.eval.x86_64.<id>:latest` | Created for eval, cleaned after |
| TAG2 | `mswebench/<repo>:pr-<id>` | Created for eval, cleaned after |
| Runtime Image | `ghcr.io/openhands/runtime:*` | Created during trajectory, cleaned after |

### Disk Space Requirements

| Operation | Approximate Size |
|-----------|------------------|
| Docker image (typical) | 2-5 GB |
| Runtime image | 1-3 GB |
| Trajectory output | 10-100 MB |
| Total per instance (peak) | 5-10 GB |

**Recommendation**: Ensure at least 20 GB free disk space.

---

## Complete Examples

### Example 1: First-Time Setup and Batch Run

```bash
# Navigate to VeloraHarness
cd /home/ubuntu/Velora_SWE_Harness-4/VeloraHarness

# Step 1: Copy SSH key to server (from your local Mac)
# Run this on your LOCAL machine, not the server:
# scp ~/Downloads/velora-us.pem ubuntu@<server-ip>:~/.ssh/
# Then on server: chmod 600 ~/.ssh/velora-us.pem

# Step 2: Setup remote AWS hosts
./evaluation/benchmarks/multi_swe_bench/scripts/setup_remote_hosts.sh \
  --hosts "34.230.26.157,54.89.56.184" \
  --ssh-key ~/.ssh/velora-us.pem

# Step 3: Run batch evaluation
./evaluation/benchmarks/multi_swe_bench/scripts/run_batch_eval.sh \
  --model llm.gemini3 \
  --dataset-dir ./dataset/ \
  --max-iter 30 \
  --aws-hosts "34.230.26.157,54.89.56.184" \
  --ssh-key ~/.ssh/velora-us.pem
```

### Example 2: Re-Running After Changes

```bash
# Force re-sync code changes to remote hosts
./evaluation/benchmarks/multi_swe_bench/scripts/setup_remote_hosts.sh \
  --hosts "34.230.26.157,54.89.56.184" \
  --ssh-key ~/.ssh/velora-us.pem \
  --force-sync \
  --skip-poetry-install

# Run batch evaluation
./evaluation/benchmarks/multi_swe_bench/scripts/run_batch_eval.sh \
  --model llm.gemini3 \
  --dataset-dir ./dataset/ \
  --aws-hosts "34.230.26.157,54.89.56.184" \
  --ssh-key ~/.ssh/velora-us.pem
```

### Example 3: Testing Single Instance Before Batch

```bash
# Test one instance first
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh \
  llm.gemini3 \
  ./dataset/518290527943513.jsonl

# Check results
cat evaluation/evaluation_outputs/outputs/*/CodeActAgent/*/eval_outputs/518290527943513/report.json

# If successful, run all instances
./evaluation/benchmarks/multi_swe_bench/scripts/run_batch_eval.sh \
  --model llm.gemini3 \
  --dataset-dir ./dataset/
```

### Example 4: Using Different Models

```bash
# With Gemini
./evaluation/benchmarks/multi_swe_bench/scripts/run_batch_eval.sh \
  --model llm.gemini3 \
  --dataset-dir ./dataset/ \
  --max-iter 30

# With GPT (usually needs more iterations)
./evaluation/benchmarks/multi_swe_bench/scripts/run_batch_eval.sh \
  --model llm.gpt \
  --dataset-dir ./dataset/ \
  --max-iter 100

# With Claude
./evaluation/benchmarks/multi_swe_bench/scripts/run_batch_eval.sh \
  --model llm.claude \
  --dataset-dir ./dataset/ \
  --max-iter 50
```

---

## Troubleshooting

### Common Errors and Solutions

| Error | Cause | Solution |
|-------|-------|----------|
| `poetry: command not found` | Poetry not in PATH for SSH | Run `setup_remote_hosts.sh` to install |
| `TmuxCommandNotFound (exit code 3)` | Docker image missing tmux | Script auto-fixes; if persists, rebuild image |
| `No such file or directory: run_full_eval_with_s3.sh` | VeloraHarness not synced | Run `setup_remote_hosts.sh --force-sync` |
| `scp: stat local "22"` | Using `-p` instead of `-P` for scp | Fixed in latest script version |
| `Cannot connect to Docker daemon` | Docker not running | `sudo systemctl start docker` |
| `No space left on device` | Disk full | Run `docker system prune -af --volumes` |
| `S3 download failed` | AWS credentials issue | Check `aws configure` on remote |
| `SSH connection refused` | Wrong key/port/host | Verify SSH settings manually |

### Debugging Commands

```bash
# Check Docker disk usage
docker system df

# List all images
docker images | grep -E "(mswebench|openhands)"

# Clean all Docker data
docker system prune -af --volumes

# Test SSH to remote host
ssh -i ~/.ssh/velora-us.pem ubuntu@34.230.26.157 "echo 'OK'"

# Check Poetry on remote
ssh -i ~/.ssh/velora-us.pem ubuntu@34.230.26.157 \
  "source ~/.bashrc; export PATH=\$HOME/.local/bin:\$PATH; poetry --version"

# Check AWS credentials on remote
ssh -i ~/.ssh/velora-us.pem ubuntu@34.230.26.157 "aws sts get-caller-identity"

# View trajectory output
cat evaluation/evaluation_outputs/outputs/.../output.jsonl | python3 -m json.tool

# View evaluation report
cat evaluation/evaluation_outputs/outputs/.../eval_outputs/*/report.json | python3 -m json.tool
```

---

## Output Files Reference

### Single Instance Output Structure

```
evaluation/evaluation_outputs/outputs/
└── __path__to__dataset.jsonl-train/
    └── CodeActAgent/
        └── gemini-3-pro-preview_maxiter_30_N_v1.1.0-no-hint-run_1/
            ├── output.jsonl              # Trajectory + git_patch
            ├── metadata.json             # Run metadata
            ├── llm_completions/          # Raw LLM responses
            │   └── *.json
            ├── logs/                     # Execution logs
            ├── eval_pilot2_output.jsonl  # Evaluation results
            └── eval_outputs/
                ├── report.json           # Aggregate report
                └── <instance_id>/
                    ├── report.json       # Instance report
                    ├── patch.diff        # Applied patch
                    ├── test_output.txt   # Pytest output
                    └── run_instance.log  # Eval log
```

### Batch Evaluation Output Structure

```
evaluation/batch_logs/
└── 20260128_053708/                    # Timestamp directory
    ├── config.json                     # Run configuration
    ├── distribution.json               # Instance → Host mapping
    ├── progress.json                   # Real-time progress (local)
    ├── summary.json                    # Final aggregated results
    ├── worker_script.sh                # Worker script (distributed)
    │
    │   # Local mode:
    ├── <instance_id>.log               # Per-instance logs
    │
    │   # Distributed mode:
    ├── worker_host0.log                # Host 0 worker log
    ├── worker_host1.log                # Host 1 worker log
    └── outputs_host0/                  # Collected from Host 0
        └── evaluation_outputs/...
```

### Report JSON Structure

```json
{
  "518290527943513": {
    "patch_is_None": false,
    "patch_exists": true,
    "patch_successfully_applied": true,
    "resolved": true,
    "tests_status": {
      "FAIL_TO_PASS": {
        "success": ["test_case_1", "test_case_2"],
        "failure": []
      },
      "PASS_TO_PASS": {
        "success": ["test_case_3", "test_case_4"],
        "failure": []
      },
      "FAIL_TO_FAIL": {"success": [], "failure": []},
      "PASS_TO_FAIL": {"success": [], "failure": []}
    }
  }
}
```

### Summary JSON Structure (Batch)

```json
{
  "timestamp": "20260128_053708",
  "model_config": "llm.gemini3",
  "total_instances": 7,
  "completed": [
    {"id": "518290527943513", "duration": 245},
    {"id": "538997559166630", "duration": 312}
  ],
  "failed": [
    {"id": "546207528428803", "exit_code": 1, "duration": 45}
  ],
  "results": {
    "518290527943513": {
      "resolved": true,
      "patch_applied": true,
      "source": "outputs_host0/..."
    }
  },
  "stats": {
    "total": 7,
    "completed": 5,
    "failed": 2,
    "resolved": 3,
    "patch_applied": 4
  }
}
```

---

## Quick Reference Card

### Commands Cheat Sheet

```bash
# Setup hosts
./setup_remote_hosts.sh --hosts "h1,h2" --ssh-key ~/.ssh/key.pem

# Check hosts only
./setup_remote_hosts.sh --hosts "h1,h2" --ssh-key ~/.ssh/key.pem --check-only

# Single instance eval
./run_full_eval_with_s3.sh llm.gemini3 ./dataset/instance.jsonl

# Batch local
./run_batch_eval.sh -m llm.gemini3 -d ./dataset/

# Batch distributed
./run_batch_eval.sh -m llm.gemini3 -d ./dataset/ --aws-hosts "h1,h2" --ssh-key ~/.ssh/key.pem

# Dry run
./run_batch_eval.sh -m llm.gemini3 -d ./dataset/ --aws-hosts "h1,h2" --dry-run

# Resume from instance
./run_batch_eval.sh -m llm.gemini3 -d ./dataset/ --resume-from "INSTANCE_ID"
```

### Key Configuration Files

| File | Purpose |
|------|---------|
| `config.toml` | LLM API configurations |
| `dataset/*.jsonl` | Instance definitions |
| `~/.ssh/velora-us.pem` | SSH key for AWS hosts |
| `~/.aws/credentials` | AWS S3 access |

---

*Documentation Version: 2.0 | Last Updated: January 2026*
