# Setup Summary - Task Runner System

## ✅ What Was Completed

### 1. CSV to JSON Conversion ✓
- **Source**: `repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv` (230,833 rows)
- **Output**: `data/repomate_100_tasks.jsonl` (100 tasks)
- **Tool**: `convert_csv_to_json.py`

### 2. Task Distribution ✓
100 tasks across 7 programming languages:
- Python: 23 tasks
- Go: 18 tasks
- JavaScript: 17 tasks
- Rust: 15 tasks
- Java: 13 tasks
- C: 11 tasks
- C++: 3 tasks

### 3. Shell Script Updated ✓
Modified `run_instance_wise_trajectories.sh` to support:
- **Command-line argument**: Run N tasks directly (e.g., `./run_instance_wise_trajectories.sh 10`)
- **Interactive mode**: Run without arguments for full menu
- **Task range**: 1-100 tasks
- **Automatic validation**: Checks if number is valid (1-100)

## 🚀 Usage Examples

### Run 1 Task
```bash
./run_instance_wise_trajectories.sh 1
```

### Run 10 Tasks
```bash
./run_instance_wise_trajectories.sh 10
```

### Run 50 Tasks
```bash
./run_instance_wise_trajectories.sh 50
```

### Run All 100 Tasks
```bash
./run_instance_wise_trajectories.sh 100
```

### Interactive Mode (Advanced)
```bash
./run_instance_wise_trajectories.sh
# Provides menu for:
# - Custom instance selection
# - Execution mode (sequential/parallel)
# - Model selection
```

## 📁 Files Created

1. **convert_csv_to_json.py** - CSV to JSONL converter
   - Location: `/home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness/`
   - Usage: `python3 convert_csv_to_json.py [NUM_TASKS]`

2. **data/repomate_100_tasks.jsonl** - Dataset with 100 tasks
   - Each task has: instance_id, task_number, language, and all CSV columns
   - Format: One JSON object per line (JSONL)

3. **QUICK_START.md** - Quick reference guide

4. **README_TASK_RUNNER.md** - Complete documentation

5. **SETUP_SUMMARY.md** - This file

## 🔧 Key Changes to Shell Script

### Before:
- Fixed dataset: `repomate_75_samples.jsonl`
- Interactive mode only
- Manual instance selection required

### After:
- Updated dataset: `repomate_100_tasks.jsonl`
- Command-line arguments: `./script.sh [NUM_TASKS]`
- Automatic task selection: Tasks 1-N
- Interactive mode still available
- Validates input range (1-100)

### Script Logic:
```bash
# If argument provided:
./run_instance_wise_trajectories.sh 10
# → Runs tasks 1-10, sequential mode, all models

# If no argument:
./run_instance_wise_trajectories.sh
# → Shows interactive menu for custom configuration
```

## 📊 Task Numbering

Tasks are numbered sequentially:
- **Task 1** = First row in CSV (after header)
- **Task 10** = 10th row in CSV
- **Task 100** = 100th row in CSV

Each task has a unique instance_id: `task_XXX_{issue_fbid}`

## 🎯 Next Steps

1. **Test with 1 task**:
   ```bash
   ./run_instance_wise_trajectories.sh 1
   ```

2. **Run small batch**:
   ```bash
   ./run_instance_wise_trajectories.sh 10
   ```

3. **Full production run**:
   ```bash
   ./run_instance_wise_trajectories.sh 100
   ```

## 🔄 Regenerate Dataset

To create dataset with different number of tasks:

```bash
# 50 tasks
python3 convert_csv_to_json.py 50
# Creates: data/repomate_50_tasks.jsonl

# 200 tasks  
python3 convert_csv_to_json.py 200
# Creates: data/repomate_200_tasks.jsonl
```

Then update the `DATASET_PATH` variable in the shell script:
```bash
readonly DATASET_PATH="${PROJECT_ROOT}/data/repomate_50_tasks.jsonl"
```

## 📝 Command Reference

| Command | Description |
|---------|-------------|
| `./run_instance_wise_trajectories.sh 1` | Run 1 task |
| `./run_instance_wise_trajectories.sh 10` | Run 10 tasks |
| `./run_instance_wise_trajectories.sh 100` | Run all 100 tasks |
| `./run_instance_wise_trajectories.sh` | Interactive mode |
| `python3 convert_csv_to_json.py 100` | Regenerate 100-task dataset |

## ⚙️ Models & Configuration

All runs use:
- **Models**: Claude Opus 4.6, GPT-5.2, Kimi K2.5, Qwen 3 Coder Plus
- **Temperature**: 1.0 (for diverse trajectories)
- **Max Iterations**: 500
- **Agent**: CodeActAgent
- **Default Mode**: Sequential (when using command-line args)

## 🎉 System Ready!

The system is now configured to run 1-100 tasks with a single command.
See QUICK_START.md for immediate usage or README_TASK_RUNNER.md for full documentation.
