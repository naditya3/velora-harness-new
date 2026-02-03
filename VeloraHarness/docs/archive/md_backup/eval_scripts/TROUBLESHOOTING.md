# Multi-SWE-Bench Evaluation - Troubleshooting & Fixes Guide

This document details all the issues encountered during batch evaluation setup and the fixes applied to resolve them.

---

## Table of Contents

1. [Quick Start Commands](#quick-start-commands)
2. [Issues and Fixes Summary](#issues-and-fixes-summary)
3. [Detailed Issue Analysis](#detailed-issue-analysis)
4. [Pre-Evaluation Checklist](#pre-evaluation-checklist)
5. [Common Errors and Solutions](#common-errors-and-solutions)
6. [Script Modifications Made](#script-modifications-made)

---

## Quick Start Commands

### Before Running Any Batch Evaluation

```bash
# Navigate to VeloraHarness directory
cd /home/ubuntu/Velora_SWE_Harness-4/VeloraHarness

# Step 1: Run setup script to verify and fix all remote hosts
./evaluation/benchmarks/multi_swe_bench/scripts/setup_remote_hosts.sh \
  --hosts "HOST1_IP,HOST2_IP" \
  --ssh-key ~/.ssh/your-key.pem \
  --ssh-user ubuntu

# Step 2: Run batch evaluation
./evaluation/benchmarks/multi_swe_bench/scripts/run_batch_eval.sh \
  --model llm.gemini3 \
  --dataset-dir ./dataset/ \
  --max-iter 30 \
  --aws-hosts "HOST1_IP,HOST2_IP" \
  --ssh-key ~/.ssh/your-key.pem \
  --ssh-user ubuntu
```

### Resume Failed Evaluations

```bash
# Resume from a specific instance (skips already completed ones)
./evaluation/benchmarks/multi_swe_bench/scripts/run_batch_eval.sh \
  --model llm.gemini3 \
  --dataset-dir ./dataset/ \
  --max-iter 30 \
  --aws-hosts "HOST_IP" \
  --ssh-key ~/.ssh/your-key.pem \
  --ssh-user ubuntu \
  --resume-from INSTANCE_ID
```

---

## Issues and Fixes Summary

| Issue | Root Cause | Fix Applied |
|-------|------------|-------------|
| `scp: stat local "22"` | SCP uses `-P` for port, not `-p` | Created separate `SCP_OPTS` variable |
| `poetry: command not found` | SSH non-interactive sessions don't load `.bashrc` | Added profile sourcing and PATH setup in worker script |
| `bash: run_full_eval_with_s3.sh: No such file or directory` | VeloraHarness not synced to remote hosts | Added pre-flight checks and setup script |
| `ModuleNotFoundError: No module named 'pandas'` | Poetry virtual environment not properly set up | Added `poetry install` step before evaluations |
| `ModuleNotFoundError: No module named 'datasets'` | Poetry not installing `datasets` package (lock file issue) | Added fallback pip install for `datasets` |
| Task distribution conflicts | INSTANCE_IDS array not re-indexed after resume | Added re-indexing logic after slicing |
| `fatal: not a git repository` | Remote hosts don't have `.git` folder | Made git commit optional with env var fallback |

---

## Detailed Issue Analysis

### Issue 1: SCP Port Flag Error

**Error Message:**
```
scp: stat local "22": No such file or directory
```

**Root Cause:**
- SSH uses `-p` (lowercase) for port specification
- SCP uses `-P` (uppercase) for port specification
- The script was using the same options for both

**Fix Applied:**
```bash
# SSH options
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i $SSH_KEY -p $SSH_PORT"

# SCP options (note: -P uppercase for port)
SCP_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i $SSH_KEY -P $SSH_PORT"
```

---

### Issue 2: Poetry Command Not Found on Remote Hosts

**Error Message:**
```
poetry: command not found
```

**Root Cause:**
- SSH non-interactive sessions don't load `.bashrc` or `.profile`
- Poetry is installed in `~/.local/bin` which isn't in the default PATH

**Fix Applied in Worker Script:**
```bash
# Source shell profile to get poetry and other tools in PATH
if [ -f "$HOME/.bashrc" ]; then
  source "$HOME/.bashrc" 2>/dev/null || true
fi
if [ -f "$HOME/.profile" ]; then
  source "$HOME/.profile" 2>/dev/null || true
fi

# Add common poetry locations to PATH
export PATH="$HOME/.local/bin:$HOME/.poetry/bin:$PATH"
```

---

### Issue 3: Evaluation Script Not Found on Remote Hosts

**Error Message:**
```
bash: evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh: No such file or directory
```

**Root Cause:**
- VeloraHarness directory was not synced to remote hosts
- Scripts were using relative paths instead of absolute paths

**Fixes Applied:**
1. Created `setup_remote_hosts.sh` to sync VeloraHarness to remote hosts
2. Changed worker script to use absolute paths:
```bash
EVAL_SCRIPT="$VELORA_ROOT/evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh"
```
3. Added pre-flight checks in batch script

---

### Issue 4: Missing Python Dependencies (pandas)

**Error Message:**
```
ModuleNotFoundError: No module named 'pandas'
```

**Root Cause:**
- Poetry was creating a new virtual environment on remote hosts
- Dependencies weren't installed in the new virtual environment

**Fix Applied:**
- Setup script now verifies dependency imports, not just Poetry installation
- Worker script runs `poetry install` before starting evaluations

---

### Issue 5: Missing `datasets` Module

**Error Message:**
```
ModuleNotFoundError: No module named 'datasets'
```

**Root Cause:**
- Poetry was not installing `datasets` package despite it being in `pyproject.toml`
- Likely a version conflict or lock file issue

**Fix Applied:**
Added fallback pip install in both `setup_remote_hosts.sh` and worker script:
```bash
# If datasets is missing after poetry install, install it explicitly
poetry run pip install datasets
```

---

### Issue 6: Task Distribution After Resume

**Error Message:**
No error, but tasks were being assigned incorrectly after using `--resume-from`

**Root Cause:**
- After slicing `ALL_INSTANCES` array for resume, `INSTANCE_IDS` associative array wasn't re-indexed
- This caused incorrect instance ID lookups

**Fix Applied:**
```bash
# CRITICAL: Re-index INSTANCE_IDS to match sliced ALL_INSTANCES
declare -A NEW_INSTANCE_IDS
for i in "${!ALL_INSTANCES[@]}"; do
  file="${ALL_INSTANCES[$i]}"
  instance_id=$(cat "$file" | python3 -c "import sys,json; print(json.load(sys.stdin).get('instance_id','unknown'))" 2>/dev/null || basename "$file" .jsonl)
  NEW_INSTANCE_IDS[$i]="$instance_id"
done
# Replace old INSTANCE_IDS with re-indexed version
unset INSTANCE_IDS
declare -A INSTANCE_IDS
for i in "${!NEW_INSTANCE_IDS[@]}"; do
  INSTANCE_IDS[$i]="${NEW_INSTANCE_IDS[$i]}"
done
```

---

### Issue 7: Git Repository Not Found on Remote Hosts

**Error Message:**
```
fatal: not a git repository (or any of the parent directories): .git
subprocess.CalledProcessError: Command '['git', 'rev-parse', 'HEAD']' returned non-zero exit status 128.
```

**Root Cause:**
- The `make_metadata` function in `evaluation/utils/shared.py` calls `git rev-parse HEAD` to capture the git commit hash
- When VeloraHarness is synced to remote hosts via rsync/scp, the `.git` folder is not included
- This causes the evaluation to fail immediately when trying to create metadata

**Fixes Applied:**

1. **Updated `shared.py` to handle non-git environments:**
```python
# Get git commit hash, with fallback for non-git environments (e.g., remote hosts)
try:
    git_commit = subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'],
        stderr=subprocess.DEVNULL
    ).decode('utf-8').strip()
except (subprocess.CalledProcessError, FileNotFoundError):
    # Not a git repository or git not available - use fallback
    git_commit = os.environ.get('OPENHANDS_GIT_COMMIT', 'unknown')
    logger.warning(f'Not a git repository, using git_commit={git_commit}')
```

2. **Updated `run_batch_eval.sh` to capture and pass git commit to remote hosts:**
```bash
# In run_distributed() function:
# Capture git commit hash from local repository to pass to remote hosts
LOCAL_GIT_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

# When launching worker via SSH:
ssh $SSH_OPTS "${SSH_USER}@${host}" "export OPENHANDS_GIT_COMMIT='$LOCAL_GIT_COMMIT' && ..."
```

---

## Pre-Evaluation Checklist

### Local Machine (Controller)

- [ ] SSH key has correct permissions: `chmod 600 ~/.ssh/your-key.pem`
- [ ] Can SSH to all remote hosts without password prompt
- [ ] VeloraHarness directory exists and has all scripts
- [ ] Dataset files are in the correct directory (`.jsonl` format)
- [ ] `config.toml` has valid API keys

### Remote Hosts

Run the setup script to automatically check and fix these:

```bash
./evaluation/benchmarks/multi_swe_bench/scripts/setup_remote_hosts.sh \
  --hosts "HOST1,HOST2" \
  --ssh-key ~/.ssh/key.pem \
  --check-only  # Add this flag to only check without fixing
```

The setup script verifies:

| Check | Auto-Fix Available |
|-------|-------------------|
| SSH connectivity | No |
| VeloraHarness directory | Yes (syncs from local) |
| Evaluation script exists | Yes (via VeloraHarness sync) |
| Poetry installed | Yes (installs automatically) |
| Poetry dependencies (pandas, datasets) | Yes (installs and pip fallback) |
| Docker accessible | Partial (adds user to docker group) |
| AWS CLI installed | No |
| AWS credentials configured | Yes (syncs from local) |
| config.toml exists | Yes (syncs from local) |
| Disk space (>10GB free) | Partial (Docker cleanup) |

---

## Common Errors and Solutions

### Error: "Cannot SSH to host"

**Solution:**
```bash
# Check SSH key permissions
chmod 600 ~/.ssh/your-key.pem

# Test SSH connection manually
ssh -i ~/.ssh/your-key.pem ubuntu@HOST_IP "echo OK"

# Check if SSH port is correct (default: 22)
ssh -i ~/.ssh/your-key.pem -p PORT ubuntu@HOST_IP "echo OK"
```

### Error: "Poetry install failed"

**Solution:**
```bash
# SSH to the remote host
ssh -i ~/.ssh/your-key.pem ubuntu@HOST_IP

# Clear poetry cache and reinstall
cd /home/ubuntu/Velora_SWE_Harness-4/VeloraHarness
~/.local/bin/poetry env remove --all
~/.local/bin/poetry install --sync --no-interaction

# If datasets is still missing
~/.local/bin/poetry run pip install datasets
```

### Error: "Docker not accessible"

**Solution:**
```bash
# SSH to the remote host
ssh -i ~/.ssh/your-key.pem ubuntu@HOST_IP

# Add user to docker group
sudo usermod -aG docker $USER

# Logout and login again, or run:
newgrp docker

# Verify
docker info
```

### Error: "Disk space low"

**Solution:**
```bash
# SSH to the remote host and clean up Docker
ssh -i ~/.ssh/your-key.pem ubuntu@HOST_IP

# Remove all unused Docker resources
docker system prune -a -f --volumes

# Check space
df -h
```

### Error: "AWS credentials not configured"

**Solution:**
The setup script will sync `~/.aws/credentials` from local machine. Alternatively:
```bash
# SSH to remote host
ssh -i ~/.ssh/your-key.pem ubuntu@HOST_IP

# Configure AWS credentials
aws configure
# Enter: AWS Access Key ID, Secret Access Key, Region (us-east-1), Output format (json)
```

---

## Script Modifications Made

### 1. `run_batch_eval.sh`

| Line Range | Modification |
|------------|--------------|
| 504-505 | Added separate `SSH_OPTS` and `SCP_OPTS` variables |
| 270-282 | Added INSTANCE_IDS re-indexing after resume |
| 542-569 | Enhanced pre-flight check with dependency verification |
| 525-548 | Worker script: Added dependency verification with pip fallback |
| 416-418 | Capture git commit hash from local repo to pass to remote hosts |
| 789-792 | Pass `OPENHANDS_GIT_COMMIT` env var when launching SSH worker |

### 2. `setup_remote_hosts.sh`

| Line Range | Modification |
|------------|--------------|
| 295-337 | Enhanced dependency check to verify `pandas` AND `datasets` imports |
| 316-328 | Added fallback pip install for `datasets` module |

### 3. `run_full_eval_with_s3.sh`

| Line Range | Modification |
|------------|--------------|
| 668-718 | Added POST-RUN CLEANUP section for Docker images |

### 4. `evaluation/utils/shared.py`

| Line Range | Modification |
|------------|--------------|
| 193-202 | Made git commit optional with try/except and env var fallback |

---

## Verification Commands

### Verify Remote Host is Ready

```bash
# Quick verification
ssh -i ~/.ssh/key.pem ubuntu@HOST_IP "cd /home/ubuntu/Velora_SWE_Harness-4/VeloraHarness && ~/.local/bin/poetry run python -c 'import pandas; import datasets; print(\"OK\")'"
```

### Verify Docker Images Can Be Loaded

```bash
# Check Docker is working
ssh -i ~/.ssh/key.pem ubuntu@HOST_IP "docker info | head -5"

# Check available space
ssh -i ~/.ssh/key.pem ubuntu@HOST_IP "df -h /"
```

### Verify AWS Access

```bash
# Test S3 access
ssh -i ~/.ssh/key.pem ubuntu@HOST_IP "aws s3 ls s3://your-bucket/path/ --max-items 1"
```

---

## Log Files Location

After running batch evaluation, logs are stored in:

```
/home/ubuntu/Velora_SWE_Harness-4/VeloraHarness/evaluation/batch_logs/YYYYMMDD_HHMMSS/
├── distribution.json      # Task distribution across hosts
├── summary.json           # Final evaluation summary
├── worker_host0.log       # Logs from host 0
├── worker_host1.log       # Logs from host 1
└── outputs_host0/         # Evaluation outputs from host 0
    └── outputs/           # Contains trajectory and eval results
```

---

## Contact & Support

If you encounter issues not covered in this guide:

1. Check the worker logs in `batch_logs/TIMESTAMP/worker_hostN.log`
2. SSH to the problematic host and run commands manually to diagnose
3. Verify the setup script passes all checks before running batch evaluation

---

*Last Updated: January 28, 2026*
