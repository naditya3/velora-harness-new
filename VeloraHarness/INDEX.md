# 📑 Automation System Index

## Quick Navigation

### 🚀 Getting Started
1. [QUICK_START.md](QUICK_START.md) - Start here! 5-minute setup
2. [verify_setup.sh](verify_setup.sh) - Run this to check your setup
3. [run_multi_model_trajectories.sh](run_multi_model_trajectories.sh) - Main automation script

### 📚 Documentation
- [README_AUTOMATION.md](README_AUTOMATION.md) - System overview and features
- [MULTIMODEL_TRAJECTORY_GUIDE.md](MULTIMODEL_TRAJECTORY_GUIDE.md) - Comprehensive guide
- [CHEATSHEET.md](CHEATSHEET.md) - Quick command reference
- **[INDEX.md](INDEX.md)** - This file

### 🔧 Configuration
- [config.toml](config.toml) - Main configuration (ADD YOUR API KEYS HERE!)
- [config.toml.example](config.toml.example) - Configuration template

### 💾 Data
- [data/repomate_75_samples.jsonl](data/repomate_75_samples.jsonl) - Ready-to-use dataset (75 samples)
- Source: `/home/ec2-user/VeloraTrajectories/repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv`

### 🛠️ Scripts
- [run_multi_model_trajectories.sh](run_multi_model_trajectories.sh) - Main automation
- [verify_setup.sh](verify_setup.sh) - Setup verification
- [scripts/prepare_repomate_dataset.py](scripts/prepare_repomate_dataset.py) - Dataset preparation

---

## 🎯 What to Read First

### If you're new to this system:
1. Read [QUICK_START.md](QUICK_START.md) (5 minutes)
2. Run `./verify_setup.sh`
3. Edit `config.toml` to add API keys
4. Run `./run_multi_model_trajectories.sh`

### If you want detailed information:
1. Read [README_AUTOMATION.md](README_AUTOMATION.md) for overview
2. Read [MULTIMODEL_TRAJECTORY_GUIDE.md](MULTIMODEL_TRAJECTORY_GUIDE.md) for details
3. Keep [CHEATSHEET.md](CHEATSHEET.md) handy for commands

### If you just need commands:
1. Jump to [CHEATSHEET.md](CHEATSHEET.md)

---

## 📊 System Components

### Models (4 total)
1. **Claude Opus 4.6** - `opus` in config.toml
2. **GPT-5.2** - `gpt` in config.toml
3. **Kimi K2.5** - `kimi` in config.toml
4. **Qwen 3 Coder Plus** - `qwen` in config.toml

### Execution Modes (3 options)
1. **Sequential** - Run one model at a time
2. **Parallel** - Run all models simultaneously
3. **Custom** - Choose specific models

### Dataset
- **Size**: 75 samples
- **Source**: repomate CSV with 230K+ lines
- **Format**: JSONL (SWE-bench compatible)
- **Location**: `data/repomate_75_samples.jsonl`

---

## 🗂️ File Organization

```
VeloraHarness/
├── Documentation
│   ├── QUICK_START.md              ← Start here
│   ├── README_AUTOMATION.md        ← Overview
│   ├── MULTIMODEL_TRAJECTORY_GUIDE.md ← Full guide
│   ├── CHEATSHEET.md               ← Commands
│   └── INDEX.md                    ← This file
│
├── Scripts
│   ├── run_multi_model_trajectories.sh ← Main script
│   ├── verify_setup.sh             ← Setup checker
│   └── scripts/
│       └── prepare_repomate_dataset.py ← Dataset prep
│
├── Configuration
│   ├── config.toml                 ← Main config (edit this!)
│   └── config.toml.example         ← Template
│
├── Data
│   └── data/
│       └── repomate_75_samples.jsonl ← Ready dataset
│
└── Output (generated when run)
    ├── evaluation/evaluation_outputs/outputs/
    └── ../../outputs/multimodel_logs_*/
```

---

## ⚡ Quick Commands

```bash
# Navigate to project
cd /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness

# Check setup
./verify_setup.sh

# Run automation
./run_multi_model_trajectories.sh

# View this index
cat INDEX.md
```

---

## 🆘 Need Help?

1. **Setup issues**: Run `./verify_setup.sh`
2. **Command help**: Read [CHEATSHEET.md](CHEATSHEET.md)
3. **Understanding the system**: Read [README_AUTOMATION.md](README_AUTOMATION.md)
4. **Step-by-step guide**: Read [MULTIMODEL_TRAJECTORY_GUIDE.md](MULTIMODEL_TRAJECTORY_GUIDE.md)

---

## 📞 Support Checklist

Before asking for help:
- [ ] Ran `./verify_setup.sh`
- [ ] Checked API keys in `config.toml`
- [ ] Verified Docker is running (`docker ps`)
- [ ] Checked disk space (`df -h`)
- [ ] Reviewed logs in `../../outputs/multimodel_logs_*/`

---

**Last Updated**: 2026-02-06
**Version**: 1.0
**Status**: ✅ Production Ready

---

## 🎉 Ready to Start?

```bash
cd /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness
./run_multi_model_trajectories.sh
```
