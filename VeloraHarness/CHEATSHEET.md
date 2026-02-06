# 🎯 Quick Reference Cheatsheet

## Essential Commands

### Run Everything
```bash
cd /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness
./run_multi_model_trajectories.sh
```

### Verify Setup
```bash
./verify_setup.sh
```

### Prepare Dataset Only
```bash
python3 scripts/prepare_repomate_dataset.py 75
```

### Run Single Model
```bash
# Claude Opus
sg docker -c "python3 evaluation/benchmarks/swe_bench/run_infer.py \
    --agent-cls CodeActAgent --llm-config opus \
    --max-iterations 500 --dataset data/repomate_75_samples.jsonl \
    --split train --eval-note my_opus_run"

# GPT-5.2
sg docker -c "python3 evaluation/benchmarks/swe_bench/run_infer.py \
    --agent-cls CodeActAgent --llm-config gpt \
    --max-iterations 500 --dataset data/repomate_75_samples.jsonl \
    --split train --eval-note my_gpt_run"

# Kimi K2.5
sg docker -c "python3 evaluation/benchmarks/swe_bench/run_infer.py \
    --agent-cls CodeActAgent --llm-config kimi \
    --max-iterations 500 --dataset data/repomate_75_samples.jsonl \
    --split train --eval-note my_kimi_run"

# Qwen 3 Coder
sg docker -c "python3 evaluation/benchmarks/swe_bench/run_infer.py \
    --agent-cls CodeActAgent --llm-config qwen \
    --max-iterations 500 --dataset data/repomate_75_samples.jsonl \
    --split train --eval-note my_qwen_run"
```

## File Locations

### Scripts
- Main: `run_multi_model_trajectories.sh`
- Verify: `verify_setup.sh`
- Dataset prep: `scripts/prepare_repomate_dataset.py`

### Configuration
- Models: `config.toml`
- Example: `config.toml.example`

### Data
- Dataset: `data/repomate_75_samples.jsonl`
- Source CSV: `/home/ec2-user/VeloraTrajectories/repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv`

### Output
- Results: `evaluation/evaluation_outputs/outputs/data__repomate_75_samples.jsonl-train/CodeActAgent/`
- Logs: `../../outputs/multimodel_logs_*/`

### Documentation
- Quick start: `QUICK_START.md`
- Full guide: `MULTIMODEL_TRAJECTORY_GUIDE.md`
- Overview: `README_AUTOMATION.md`
- This file: `CHEATSHEET.md`

## API Key Configuration

Edit `config.toml`:
```toml
[llm.opus]
api_key = "sk-ant-YOUR_KEY"  # Anthropic

[llm.gpt]
api_key = "sk-YOUR_KEY"      # OpenAI

[llm.kimi]
api_key = "YOUR_KEY"         # Moonshot

[llm.qwen]
api_key = "YOUR_KEY"         # OpenRouter
```

## Monitoring

### Watch Logs
```bash
tail -f ../../outputs/multimodel_logs_*/opus_trajectory.log
tail -f ../../outputs/multimodel_logs_*/gpt_trajectory.log
tail -f ../../outputs/multimodel_logs_*/kimi_trajectory.log
tail -f ../../outputs/multimodel_logs_*/qwen_trajectory.log
```

### Check Progress
```bash
ls -lh evaluation/evaluation_outputs/outputs/data__repomate_75_samples.jsonl-train/CodeActAgent/
wc -l evaluation/evaluation_outputs/outputs/.../output.jsonl
```

### Resource Usage
```bash
htop        # CPU/Memory
df -h       # Disk space
docker ps   # Running containers
```

## Troubleshooting

### Regenerate Dataset
```bash
python3 scripts/prepare_repomate_dataset.py 75
ls -lh data/repomate_75_samples.jsonl
```

### Check API Keys
```bash
grep "api_key" config.toml
```

### Fix Docker Permissions
```bash
sudo usermod -aG docker $USER
newgrp docker
docker ps
```

### View All Logs
```bash
ls -ltr ../../outputs/multimodel_logs_*/
cat ../../outputs/multimodel_logs_*/*.log
```

## Execution Modes

| Mode | Command | Time | Resources |
|------|---------|------|-----------|
| Sequential | Select 1 | 8-16h | Moderate |
| Parallel | Select 2 | 2-4h | High |
| Custom | Select 3 | Variable | Variable |

## Model Settings

| Model | Config Key | Model Name | API Provider |
|-------|-----------|------------|--------------|
| Claude Opus 4.6 | opus | claude-opus-4-6 | Anthropic |
| GPT-5.2 | gpt | gpt-4o | OpenAI |
| Kimi K2.5 | kimi | moonshot-v1-128k | Moonshot |
| Qwen 3 Coder+ | qwen | qwen/qwen-2.5-coder-32b-instruct | OpenRouter |

## Quick Fixes

### Dataset missing
```bash
python3 scripts/prepare_repomate_dataset.py 75
```

### API error
```bash
nano config.toml  # Update API keys
```

### Permission denied
```bash
chmod +x run_multi_model_trajectories.sh verify_setup.sh scripts/prepare_repomate_dataset.py
```

### Out of space
```bash
df -h
du -sh evaluation/evaluation_outputs/*
```

## One-Liner Examples

```bash
# Full run - Sequential mode
echo "1" | ./run_multi_model_trajectories.sh

# Verify everything
./verify_setup.sh && echo "Ready!"

# Count samples
wc -l data/repomate_75_samples.jsonl

# Find latest output
ls -ltr evaluation/evaluation_outputs/outputs/data__repomate_75_samples.jsonl-train/CodeActAgent/ | tail -5

# Check all API keys
grep -E "^\[llm\.|api_key" config.toml
```

---

**Pro Tip**: Use `screen` or `tmux` for long-running jobs!

```bash
screen -S trajectories
./run_multi_model_trajectories.sh
# Detach: Ctrl+A, D
# Reattach: screen -r trajectories
```
