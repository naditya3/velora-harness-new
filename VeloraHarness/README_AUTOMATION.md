# 🚀 Automated Multi-Model Trajectory Generation System

## Overview

Complete automation system for generating LLM trajectories across 4 different models using 75 samples from the repomate dataset.

**Created**: February 6, 2026
**Dataset**: repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv
**Samples**: 75 data points
**Models**: Claude Opus 4.6, GPT-5.2, Kimi K2.5, Qwen 3 Coder Plus

---

## 📁 Files Created

### Main Execution Scripts

1. **[run_multi_model_trajectories.sh](run_multi_model_trajectories.sh)** - Master automation script
2. **[scripts/prepare_repomate_dataset.py](scripts/prepare_repomate_dataset.py)** - Dataset converter
3. **[verify_setup.sh](verify_setup.sh)** - Pre-flight checker

### Documentation

4. **[QUICK_START.md](QUICK_START.md)** - 5-minute setup guide
5. **[MULTIMODEL_TRAJECTORY_GUIDE.md](MULTIMODEL_TRAJECTORY_GUIDE.md)** - Comprehensive manual

---

## 🎯 Quick Start

```bash
cd /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness
./run_multi_model_trajectories.sh
```

See [QUICK_START.md](QUICK_START.md) for detailed instructions.
