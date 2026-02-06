# Quick Start Guide

## ✅ Setup Complete!

Your dataset has been converted and the script is ready to use.

## 📊 Dataset Summary

- **Location**: `data/repomate_100_tasks.jsonl`
- **Total Tasks**: 100
- **Tasks are numbered**: 1-100
- **Languages**: Python (23), Go (18), JavaScript (17), Rust (15), Java (13), C (11), C++ (3)

## 🚀 How to Run

### Option 1: Run Specific Number of Tasks (Recommended)

```bash
cd /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness

# Run 1 task (for testing)
./run_instance_wise_trajectories.sh 1

# Run 10 tasks
./run_instance_wise_trajectories.sh 10

# Run 100 tasks (full dataset)
./run_instance_wise_trajectories.sh 100
```

### Option 2: Interactive Mode

```bash
./run_instance_wise_trajectories.sh
# Then follow the prompts
```

## 📝 Examples

### Test Run (1 task)
```bash
./run_instance_wise_trajectories.sh 1
```
This will run:
- Task 1 only
- All 4 models (Claude Opus 4.6, GPT-5.2, Kimi K2.5, Qwen 3 Coder Plus)
- Sequential execution mode (safe and reliable)

### Small Batch (10 tasks)
```bash
./run_instance_wise_trajectories.sh 10
```
This will run:
- Tasks 1-10
- All 4 models
- Sequential execution mode

### Full Run (100 tasks)
```bash
./run_instance_wise_trajectories.sh 100
```
This will run:
- All 100 tasks
- All 4 models
- Sequential execution mode

## 📍 Output Locations

After running, results will be in:
```
/home/ec2-user/VeloraTrajectories/outputs/
├── trajectories/session_{TIMESTAMP}/  # Generated trajectories
├── logs/session_{TIMESTAMP}/          # Execution logs
└── results/session_{TIMESTAMP}/       # Result summaries
```

## 🔧 Advanced Options

To use different execution modes or select specific models, run without arguments:
```bash
./run_instance_wise_trajectories.sh
```

Then you can choose:
- Sequential or parallel execution
- Specific models to run
- Custom instance selection

## ⚙️ Regenerate Dataset

To create a dataset with different number of tasks:

```bash
# Generate 50 tasks
python3 convert_csv_to_json.py 50

# Generate 200 tasks
python3 convert_csv_to_json.py 200
```

**Note**: After generating, update `DATASET_PATH` in the shell script to point to the new file.

## 🆘 Troubleshooting

### "Dataset not found" error
```bash
python3 convert_csv_to_json.py 100
```

### Permission denied
```bash
chmod +x run_instance_wise_trajectories.sh
```

### Docker not running
```bash
sudo systemctl start docker
```

## 📚 More Information

See [README_TASK_RUNNER.md](README_TASK_RUNNER.md) for complete documentation.
