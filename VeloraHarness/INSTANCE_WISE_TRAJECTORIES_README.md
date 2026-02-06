# Instance-Wise Trajectory Generation System

## Overview

This system provides **production-grade, instance-wise trajectory generation** for multiple AI models on the VeloraHarness benchmark platform. Unlike batch processing that runs all instances together, this system generates individual trajectories for each test instance, enabling:

- **Granular tracking** - Monitor each instance independently
- **Selective re-runs** - Retry only failed instances
- **Parallel execution** - Maximize throughput with controlled parallelism
- **Comprehensive analytics** - Detailed success/failure analysis
- **Resume capability** - Continue from where you left off

## What's Different? (Instance-Wise vs Batch)

### ❌ Original Batch Approach
```bash
# Runs ALL 75 instances together in one execution
python run_infer.py --dataset data/repomate_75_samples.jsonl
# Output: Single trajectory file with all instances mixed
```

### ✅ New Instance-Wise Approach
```bash
# Runs EACH instance separately
./run_instance_wise_trajectories.sh
# Output: 75 separate trajectory files, one per instance
#   - trajectories/session_XXX/opus/instance_1841270650076475/
#   - trajectories/session_XXX/opus/instance_1841270650076476/
#   - ... (and so on for each instance and model)
```

## Architecture

### Directory Structure (All Absolute Paths)

```
/home/ec2-user/VeloraTrajectories/
├── jaeger/VeloraHarness/                          # Project root
│   ├── run_instance_wise_trajectories.sh          # Main execution script
│   ├── instance_trajectory_manager.py             # Analysis & management tool
│   ├── data/
│   │   └── repomate_75_samples.jsonl              # Dataset (75 instances)
│   └── config/                                     # Config files
│
└── outputs/                                        # All outputs (absolute path)
    ├── trajectories/                               # Generated trajectories
    │   └── session_20260206_120000/                # Session-specific
    │       ├── opus/                               # Model-specific
    │       │   ├── instance_1841270650076475/      # Instance-specific
    │       │   │   ├── output.jsonl
    │       │   │   └── eval_output.jsonl
    │       │   └── instance_1841270650076476/
    │       ├── gpt/
    │       ├── kimi/
    │       └── qwen/
    │
    ├── logs/                                       # Execution logs
    │   └── session_20260206_120000/
    │       ├── main.log                            # Main execution log
    │       ├── opus/
    │       │   ├── instance_1841270650076475.log
    │       │   └── instance_1841270650076476.log
    │       └── gpt/
    │
    ├── progress/                                   # Progress tracking
    │   └── session_20260206_120000/
    │       ├── opus_1841270650076475.status        # Per-instance status
    │       ├── opus_1841270650076476.status
    │       └── gpt_1841270650076475.status
    │
    └── results/                                    # Analysis results
        └── session_20260206_120000/
            ├── final_report.txt                    # Summary report
            ├── results.csv                         # CSV export
            ├── opus_summary.txt                    # Per-model summary
            └── progress_report.txt                 # Real-time progress
```

### Status File Format

Each instance has a status file tracking its execution:

```
SUCCESS|1738854321|1247
FAILED|1738854321|532|1
TIMEOUT|1738854321|7200
IN_PROGRESS|1738854321
```

Format: `STATUS|timestamp|duration_seconds|exit_code`

## Components

### 1. Main Execution Script (`run_instance_wise_trajectories.sh`)

**Production-grade Bash script** with:
- ✅ Complete error handling and logging
- ✅ Absolute paths throughout
- ✅ Real-time progress tracking
- ✅ Multiple execution modes
- ✅ Resource management
- ✅ Timeout protection

### 2. Management Tool (`instance_trajectory_manager.py`)

**Python utility** for:
- 📊 Results analysis and visualization
- 🔄 Retry list generation
- 📁 Subset dataset creation
- 📈 Performance metrics
- 💾 Export to CSV/JSON

## Quick Start

### Prerequisites

```bash
# Ensure all dependencies are available
python3 --version  # Python 3.8+
docker --version   # Docker for containers
jq --version       # JSON processing

# Verify dataset exists
ls -lh /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness/data/repomate_75_samples.jsonl
```

### Basic Usage

```bash
# Navigate to project root
cd /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness

# Run instance-wise trajectory generation (interactive)
./run_instance_wise_trajectories.sh
```

## Execution Modes

### Mode 1: Sequential (Safest)
- Processes **one instance at a time**
- Minimal resource usage
- Easy to monitor
- **Best for**: Small-scale runs, debugging

```
Model 1 → Instance 1 → Instance 2 → ... → Instance 75
Model 2 → Instance 1 → Instance 2 → ... → Instance 75
...
```

### Mode 2: Full Parallel (Fastest)
- Processes **all models and instances simultaneously**
- Maximum resource usage (⚠️ **WARNING**: Very resource intensive)
- Fastest completion time
- **Best for**: High-resource environments, urgent runs

```
All models × All instances running concurrently
(Potentially 4 models × 75 instances = 300 parallel jobs)
```

### Mode 3: Hybrid (Recommended)
- **Sequential models**, **parallel instances**
- Balanced resource usage
- Configurable parallelism (default: 4 instances at a time)
- **Best for**: Production use

```
Model 1 → [Instance 1, 2, 3, 4 parallel] → [5, 6, 7, 8] → ...
Model 2 → [Instance 1, 2, 3, 4 parallel] → [5, 6, 7, 8] → ...
```

### Mode 4: Custom
- Select specific models to run
- Sequential execution of selected models
- **Best for**: Testing, selective reruns

## Configuration

### Environment Variables

```bash
# Enable debug logging
export DEBUG=true

# Set parallel instance limit (for Mode 3)
export MAX_PARALLEL_INSTANCES=8

# Set instance timeout (seconds)
export INSTANCE_TIMEOUT=3600  # 1 hour per instance
```

### Model Configuration

Edit model list in the script if needed:

```bash
MODELS=("opus" "gpt" "kimi" "qwen")
MODEL_NAMES=(
    "Claude Opus 4.6"
    "GPT-5.2"
    "Kimi K2.5"
    "Qwen 3 Coder Plus"
)
```

## Management & Analysis

### Analyze Results

```bash
# Analyze latest session
./instance_trajectory_manager.py analyze

# Analyze specific session
./instance_trajectory_manager.py analyze --session-id session_20260206_120000

# Export to CSV with failed instances list
./instance_trajectory_manager.py analyze --export-csv results.csv --show-failed

# Export to JSON
./instance_trajectory_manager.py analyze --export-json results.json
```

### View All Sessions

```bash
./instance_trajectory_manager.py list-sessions
```

Output:
```
📋 Available Sessions (5):
────────────────────────────────────────────────────────────────────────────────
Session ID                               Created                   Instances   Status Files
────────────────────────────────────────────────────────────────────────────────
session_20260206_153000                  2026-02-06 15:30:00              75           300
session_20260206_120000                  2026-02-06 12:00:00              75           298
session_20260205_180000                  2026-02-05 18:00:00              50           200
```

### Retry Failed Instances

```bash
# Generate retry list for all failed instances
./instance_trajectory_manager.py retry --create-dataset retry_dataset.jsonl

# Retry only for specific models
./instance_trajectory_manager.py retry --models opus,gpt --create-dataset retry_opus_gpt.jsonl

# Then run with the retry dataset
# (Manually edit script to use retry_dataset.jsonl)
```

### Create Custom Subsets

```bash
# Create subset for specific instances
./instance_trajectory_manager.py create-subset \
    --instance-ids "1841270650076475,1841270650076476" \
    --output custom_subset.jsonl

# Create subset from file
./instance_trajectory_manager.py create-subset \
    --instances-file failed_instances.txt \
    --output retry_subset.jsonl

# Filter by repository
./instance_trajectory_manager.py create-subset \
    --repo "meroxa/cli" \
    --output meroxa_subset.jsonl
```

## Monitoring & Progress

### Real-Time Progress

The script automatically generates progress reports:

```bash
# View real-time progress
cat /home/ec2-user/VeloraTrajectories/outputs/results/session_*/progress_report.txt

# Monitor specific model
tail -f /home/ec2-user/VeloraTrajectories/outputs/logs/session_*/opus/instance_*.log

# Watch overall progress
watch -n 10 'find /home/ec2-user/VeloraTrajectories/outputs/progress/session_* -name "*.status" | wc -l'
```

### Status Checking

```bash
# Count successful instances
grep -r "SUCCESS" /home/ec2-user/VeloraTrajectories/outputs/progress/session_*/

# Count failed instances
grep -r "FAILED" /home/ec2-user/VeloraTrajectories/outputs/progress/session_*/

# Count timed-out instances
grep -r "TIMEOUT" /home/ec2-user/VeloraTrajectories/outputs/progress/session_*/

# Still running
grep -r "IN_PROGRESS" /home/ec2-user/VeloraTrajectories/outputs/progress/session_*/
```

## Results & Reports

### Final Report

After completion, view the comprehensive report:

```bash
cat /home/ec2-user/VeloraTrajectories/outputs/results/session_*/final_report.txt
```

Example output:
```
================================================================================
  Final Results Summary
================================================================================
Session ID: session_20260206_120000
Dataset: repomate_75_samples.jsonl
Total Instances: 75
Completion Time: 2026-02-06 18:45:23

═══════════════════════════════════════
  Claude Opus 4.6
═══════════════════════════════════════
Model: Claude Opus 4.6
Configuration: opus
Total Instances: 75
Successful: 68
Failed: 5
Timed Out: 2
Success Rate: 90.67%
Completion Time: 2026-02-06 15:30:00

═══════════════════════════════════════
  GPT-5.2
═══════════════════════════════════════
...
```

### CSV Export

Results are automatically exported to CSV:

```bash
# View CSV results
column -t -s, /home/ec2-user/VeloraTrajectories/outputs/results/session_*/results.csv | less -S
```

Format:
```
Model,Instance_ID,Status,Duration_Seconds,Exit_Code
opus,1841270650076475,SUCCESS,1247,0
opus,1841270650076476,FAILED,532,1
gpt,1841270650076475,SUCCESS,892,0
```

## Advanced Usage

### Custom Instance Selection

1. **Extract specific instances from dataset:**

```bash
# Using jq to filter instances
jq -c 'select(.repo == "meroxa/cli")' \
    /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness/data/repomate_75_samples.jsonl \
    > meroxa_only.jsonl

# Count instances in filtered dataset
wc -l meroxa_only.jsonl
```

2. **Run with custom dataset:**

Edit the script and change:
```bash
DATASET_PATH="${PROJECT_ROOT}/data/meroxa_only.jsonl"
```

### Parallel Instance Control

```bash
# Run with 10 parallel instances (Mode 3)
export MAX_PARALLEL_INSTANCES=10
./run_instance_wise_trajectories.sh
```

### Resume After Interruption

```bash
# 1. Analyze what's completed
./instance_trajectory_manager.py analyze --show-failed

# 2. Generate retry list
./instance_trajectory_manager.py retry --create-dataset incomplete.jsonl

# 3. Run with incomplete dataset
# (Edit script to use incomplete.jsonl)
```

## Troubleshooting

### Common Issues

#### 1. Dataset Not Found
```
❌ Dataset not found at: /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness/data/repomate_75_samples.jsonl
```

**Solution:**
```bash
cd /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness
python3 scripts/prepare_repomate_dataset.py 75
```

#### 2. Docker Not Running
```
❌ Docker is not running or accessible
```

**Solution:**
```bash
sudo systemctl start docker
sudo usermod -aG docker $USER
newgrp docker
```

#### 3. Permission Denied
```
bash: ./run_instance_wise_trajectories.sh: Permission denied
```

**Solution:**
```bash
chmod +x /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness/run_instance_wise_trajectories.sh
chmod +x /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness/instance_trajectory_manager.py
```

#### 4. Out of Disk Space

**Check disk usage:**
```bash
df -h /home/ec2-user/VeloraTrajectories
```

**Clean old sessions:**
```bash
# Remove old session data (older than 7 days)
find /home/ec2-user/VeloraTrajectories/outputs -name "session_*" -mtime +7 -exec rm -rf {} \;
```

#### 5. Instance Hanging

**Monitor running instances:**
```bash
# Check processes
ps aux | grep run_infer

# Check Docker containers
docker ps -a

# Kill stuck instance
kill -9 <PID>
```

### Debug Mode

Enable detailed debug logging:

```bash
export DEBUG=true
./run_instance_wise_trajectories.sh
```

View debug logs:
```bash
tail -f /home/ec2-user/VeloraTrajectories/outputs/logs/session_*/debug.log
```

## Performance Optimization

### Resource Allocation

**Recommended settings based on system:**

| System RAM | CPU Cores | Mode | Parallel Instances |
|-----------|-----------|------|-------------------|
| 8 GB      | 4         | 1    | 1 (sequential)    |
| 16 GB     | 8         | 3    | 2-4               |
| 32 GB     | 16        | 3    | 4-8               |
| 64 GB+    | 32+       | 2-3  | 8-16              |

### Timeouts

Adjust based on instance complexity:

```bash
# Default: 2 hours per instance
INSTANCE_TIMEOUT=7200

# For complex instances
INSTANCE_TIMEOUT=14400  # 4 hours

# For simple instances
INSTANCE_TIMEOUT=3600   # 1 hour
```

## Best Practices

### 1. **Start Small**
```bash
# Test with a small subset first
./instance_trajectory_manager.py create-subset \
    --instance-ids "$(head -5 data/instance_ids.txt | tr '\n' ',')" \
    --output test_5_instances.jsonl
```

### 2. **Monitor Resources**
```bash
# In a separate terminal
watch -n 5 'echo "CPU:"; mpstat 1 1; echo "Memory:"; free -h; echo "Docker:"; docker stats --no-stream'
```

### 3. **Regular Backups**
```bash
# Backup results periodically
rsync -av /home/ec2-user/VeloraTrajectories/outputs/ /path/to/backup/
```

### 4. **Clean Temp Files**
```bash
# After successful completion
rm -rf /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness/temp/*
```

## Integration with Existing Workflows

### Using with Original Scripts

You can combine instance-wise trajectories with batch processing:

```bash
# Run instance-wise for critical instances
./run_instance_wise_trajectories.sh  # Mode 4, select specific models

# Run batch for remaining
./run_multi_model_trajectories.sh    # Original script
```

### Evaluating Results

Results are compatible with existing evaluation tools:

```bash
# Standard SWE-bench evaluation
python evaluation/benchmarks/swe_bench/evaluate.py \
    --trajectories /home/ec2-user/VeloraTrajectories/outputs/trajectories/session_*/opus/
```

## Support & Contribution

### Getting Help

1. Check this README
2. Review logs in `/home/ec2-user/VeloraTrajectories/outputs/logs/`
3. Run analysis: `./instance_trajectory_manager.py analyze --show-failed`

### Feature Requests

This is a production-ready system. Common enhancement requests:

- [ ] Web dashboard for real-time monitoring
- [ ] Email/Slack notifications on completion
- [ ] Automatic retry with exponential backoff
- [ ] Cost tracking per instance
- [ ] GPU utilization monitoring

## Summary

This instance-wise trajectory generation system provides:

✅ **Granular Control** - Individual instance tracking
✅ **Absolute Paths** - No relative path issues
✅ **Production-Ready** - Comprehensive error handling
✅ **Flexible Execution** - Multiple modes for different needs
✅ **Easy Analysis** - Built-in management tools
✅ **Resume Capability** - Continue from failures
✅ **Detailed Logging** - Complete audit trail

**Ready to use in production environments!**

---

*Last Updated: 2026-02-06*
*Author: Expert Coder*
