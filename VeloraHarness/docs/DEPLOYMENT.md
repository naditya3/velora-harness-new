# VeloraHarness AWS Deployment Guide

**Version:** 2.0
**Last Updated:** January 27, 2026
**Verified:** aws-instance-lancer1 (GPT, Gemini)
**Status:** ✅ Production-Ready

---

## 🎯 Quick Start

Deploy VeloraHarness to an AWS instance and run trajectory generation in 5 steps.

**Total Time:** ~5 minutes setup + execution time

---

## 📋 Prerequisites

### **Local Machine:**
- VeloraHarness source cloned
- config.toml with API keys configured
- SSH access to AWS instances (`~/.ssh/config`)

### **AWS Instance:**
- Ubuntu 20.04/22.04
- Docker installed
- Python 3.11/3.12
- 20GB+ free space

---

## 🚀 5-Step Deployment

### **Step 1: Deploy Code (30s)**

```bash
INSTANCE="lancer1"  # Change as needed

rsync -avz \
  --exclude '.git' \
  --exclude 'venv' \
  --exclude '__pycache__' \
  --exclude '*.log' \
  --exclude 'evaluation/evaluation_outputs' \
  /Users/macbookpro/Documents/SWE_Bench/Velora_SWE_Harness/VeloraHarness/ \
  aws-instance-$INSTANCE:~/VeloraHarness/
```

✅ **Expected:** ~5MB, 540 files

---

### **Step 2: Initialize Git (10s)** ⚠️ CRITICAL

```bash
ssh aws-instance-$INSTANCE "cd ~/VeloraHarness && git init && git add . && git commit -m 'Deploy $(date +%Y-%m-%d)'"
```

✅ **Expected:** Commit hash displayed

**Why required:** Script uses `git rev-parse HEAD` for metadata

---

### **Step 3: Setup Poetry (3-4min)**

```bash
ssh aws-instance-$INSTANCE bash << 'SETUP'
cd ~/VeloraHarness
export PATH="$HOME/.local/bin:$PATH"
export SKIP_VSCODE_BUILD=1

poetry install
poetry run pip install datasets

poetry run python -c "import openhands.agenthub; import datasets; print('✓ Ready')"
SETUP
```

✅ **Expected:** All packages install, final output shows "✓ Ready"

---

### **Step 4: Copy Config (5s)**

```bash
scp ~/path/to/config.toml aws-instance-$INSTANCE:~/VeloraHarness/config.toml
```

✅ **Expected:** 1.4KB transferred

---

### **Step 5: Upload Dataset (5s)**

```bash
scp /path/to/task.jsonl aws-instance-$INSTANCE:/home/ubuntu/task.jsonl
```

✅ **Expected:** Dataset file on instance

---

## ▶️ RUN TRAJECTORY GENERATION

```bash
ssh aws-instance-$INSTANCE bash << 'RUN'
cd ~/VeloraHarness

# CRITICAL exports
export PATH="$HOME/.local/bin:$PATH"
export PYTHONPATH="$(pwd):$PYTHONPATH"
export DOCKER_BUILDKIT=0
export EVAL_DOCKER_IMAGE_PREFIX="mswebench"
export USE_INSTANCE_IMAGE=true

# Run pipeline (model, dataset, limit, iterations, workers)
bash evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh \
  llm.gpt \
  /home/ubuntu/task.jsonl \
  1 \
  30 \
  1
RUN
```

**Available models:** llm.gpt, llm.claude, llm.gemini, llm.kimi, llm.qwen

---

## ✅ EXPECTED OUTPUT

```
evaluation/evaluation_outputs/outputs/.../
├── output.jsonl                  (trajectory + patch)
├── metadata.json                 (run info)
├── llm_completions/              (LLM responses)
├── eval_pilot2_output.jsonl      (evaluation results)
└── eval_outputs/                 (OpenHands format)
    └── {instance_id}/
        ├── report.json           (✅ ONLY ONE!)
        ├── patch.diff
        └── test_output.txt
```

---

## 📥 DOWNLOAD RESULTS

```bash
OUTPUT_DIR=$(ssh aws-instance-$INSTANCE "cd ~/VeloraHarness && find evaluation/evaluation_outputs/outputs -name 'output.jsonl' -mmin -60 | head -1 | xargs dirname")

rsync -avz "aws-instance-$INSTANCE:~/VeloraHarness/$OUTPUT_DIR/" ./results/
```

---

## ⚠️ CRITICAL REQUIREMENTS

| Requirement | Command | Impact if Missing |
|-------------|---------|-------------------|
| Git repository | `git init && git commit` | Script fails |
| PYTHONPATH | `export PYTHONPATH=$(pwd)` | Import errors |
| DOCKER_BUILDKIT=0 | `export DOCKER_BUILDKIT=0` | Runtime build fails |
| datasets package | `poetry run pip install datasets` | Import error |

---

## 🐛 Troubleshooting

**ModuleNotFoundError: openhands.agenthub**
```bash
export PYTHONPATH="$(pwd):$PYTHONPATH"
```

**fatal: not a git repository**
```bash
git init && git add . && git commit -m "Init"
```

**eval_outputs/ not created**
- Ensure using latest script (with export fixes)

**2 report.json files**
- Ensure using latest script (duplicate removed)

---

## 🚀 Mass Deployment

After verifying on ONE instance, deploy to all:

```bash
for i in {1..5}; do
  echo "Deploying to lancer$i..."
  rsync -avz VeloraHarness/ aws-instance-lancer${i}:~/VeloraHarness/
  ssh aws-instance-lancer${i} "cd ~/VeloraHarness && git init && git add . && git commit -m 'Deploy' && poetry install && poetry run pip install datasets"
  scp config.toml aws-instance-lancer${i}:~/VeloraHarness/
done
```

---

## ✅ Verification Checklist

- [ ] VeloraHarness deployed
- [ ] Git initialized
- [ ] Poetry packages installed
- [ ] datasets installed
- [ ] config.toml copied
- [ ] Test run completed
- [ ] output.jsonl has patch
- [ ] eval_outputs/ created
- [ ] Only 1 report.json

---

**This deployment process is verified and production-ready.**
