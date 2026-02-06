# Task Runner - Usage Guide

## Overview

This system allows you to run trajectory generation for 1-100 tasks from the repomate dataset.

## Files

- **convert_csv_to_json.py**: Converts CSV data to JSONL format
- **run_instance_wise_trajectories.sh**: Runs trajectory generation for specified tasks
- **data/repomate_100_tasks.jsonl**: Pre-converted dataset with 100 tasks

## Quick Start

### 1. Run specific number of tasks

```bash
# Run 1 task
./run_instance_wise_trajectories.sh 1

# Run 10 tasks
./run_instance_wise_trajectories.sh 10

# Run 50 tasks
./run_instance_wise_trajectories.sh 50

# Run all 100 tasks
./run_instance_wise_trajectories.sh 100
```

### 2. Interactive Mode

Run without arguments for interactive selection:

```bash
./run_instance_wise_trajectories.sh
```

This will prompt you to:
- Select single instance, all instances, or custom number
- Choose execution mode (sequential, parallel, etc.)
- Select specific models

## Dataset Conversion

To regenerate the dataset with different number of tasks:

```bash
# Convert first 100 tasks (default)
python3 convert_csv_to_json.py 100

# Convert first 50 tasks
python3 convert_csv_to_json.py 50

# Convert first 200 tasks
python3 convert_csv_to_json.py 200
```

The output will be saved to: `data/repomate_{N}_tasks.jsonl`

**Note:** After converting with a different number, update the `DATASET_PATH` in the shell script:

```bash
readonly DATASET_PATH="${PROJECT_ROOT}/data/repomate_50_tasks.jsonl"
```

## Task Numbering

Tasks are numbered 1-100 (or 1-N if you convert different amount):
- Task 1 = First instance in the CSV
- Task 10 = 10th instance in the CSV
- Task 100 = 100th instance in the CSV

## Examples

### Example 1: Test with single task
```bash
# Run just task 1 to test the system
./run_instance_wise_trajectories.sh 1
```

### Example 2: Run 10 tasks for evaluation
```bash
# Run first 10 tasks
./run_instance_wise_trajectories.sh 10
```

### Example 3: Full run
```bash
# Run all 100 tasks
./run_instance_wise_trajectories.sh 100
```

## Output Locations

Results will be saved to:
- **Trajectories**: `/home/ec2-user/VeloraTrajectories/outputs/trajectories/session_{TIMESTAMP}/`
- **Logs**: `/home/ec2-user/VeloraTrajectories/outputs/logs/session_{TIMESTAMP}/`
- **Results**: `/home/ec2-user/VeloraTrajectories/outputs/results/session_{TIMESTAMP}/`

## Command-Line vs Interactive Mode

### Command-Line Mode (Recommended for automation)
- Usage: `./run_instance_wise_trajectories.sh <NUM_TASKS>`
- Automatically uses sequential execution
- Runs all configured models
- No prompts, fully automated

### Interactive Mode
- Usage: `./run_instance_wise_trajectories.sh`
- Allows custom instance selection
- Choose execution mode (sequential/parallel)
- Select specific models
- More flexible but requires user input

## Prerequisites

Before running, ensure:
1. Docker is running
2. Python 3 is available
3. Dataset CSV file exists at: `/home/ec2-user/VeloraTrajectories/repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv`
4. Required commands available: `python3`, `jq`, `sg`, `docker`

## Troubleshooting

### Dataset not found
```bash
# Regenerate the dataset
python3 convert_csv_to_json.py 100
```

### Invalid number of tasks
- Valid range: 1-100 (or 1-N if you converted different amount)
- Must be a positive integer

### Permission denied
```bash
# Make the script executable
chmod +x run_instance_wise_trajectories.sh
chmod +x convert_csv_to_json.py
```

## Models

The system runs trajectories for 4 models:
1. Claude Opus 4.6
2. GPT-5.2
3. Kimi K2.5
4. Qwen 3 Coder Plus

All models use temperature=1.0 for diverse trajectory generation.
