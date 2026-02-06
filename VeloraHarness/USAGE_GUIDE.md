# VeloraTrajectories Instance-Wise Testing Guide

## Quick Start

The `run_instance_wise_trajectories.sh` script now supports flexible instance selection:

### Running the Script

```bash
cd /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness
./run_instance_wise_trajectories.sh
```

## Instance Selection Options

When you run the script, you'll first be asked to choose which instances to process:

### Option 1: Single Instance (Recommended for Testing)
- **Best for:** Quick testing, debugging, validation
- **Usage:** Select one specific instance from the first 10, instance #100, or enter a custom ID
- **Examples:**
  - Instance #3: Python/mypy - "Reword error message" (GRUNT_WORK difficulty)
  - Instance #100: Rust - "Clarify error message" (GRUNT_WORK difficulty)

### Option 2: All Instances (Full Run)
- **Best for:** Production trajectory generation
- **Processes:** All 75 instances in the dataset
- **Time:** Several hours to days depending on execution mode

### Option 3: Custom Number
- **Best for:** Batch testing, progressive rollout
- **Usage:** Specify any number between 1 and 75
- **Example:** Process first 10 instances for quick validation

## Execution Mode Options

After selecting instances, choose how to run them:

### Mode 1: Sequential (Safest)
- ✅ One model at a time, one instance at a time
- ✅ Most stable and predictable
- ✅ Lowest resource usage
- ⏱️ Slowest overall completion time

### Mode 2: Parallel (Fastest)
- ⚡ All models and instances run simultaneously
- ⚠️ Very high resource usage
- ⚡ Fastest overall completion time
- ⚠️ Requires significant system resources

### Mode 3: Sequential Models, Parallel Instances (Balanced)
- ⚖️ Models run one at a time
- ⚡ Each model processes up to 4 instances in parallel
- ⚖️ Good balance of speed and stability

### Mode 4: Custom Model Selection
- 🎯 Choose specific models to run
- ✅ Good for testing specific models
- 💡 Example: "1 3" runs Claude Opus and Kimi only

## Recommended Workflows

### Testing Workflow (New Setup)
```
1. Select: Single Instance → #3 (Python/mypy)
2. Mode: Sequential
3. Model: Start with one model (e.g., Claude Opus)
4. Verify: Check outputs before full run
```

### Development Workflow
```
1. Select: Custom Number → 5-10 instances
2. Mode: Sequential Models, Parallel Instances
3. Models: Test 1-2 models
4. Validate: Review results before scaling
```

### Production Workflow (Full Run)
```
1. Select: All Instances
2. Mode: Sequential Models, Parallel Instances
3. Models: All models
4. Monitor: Check progress reports regularly
```

## Instance Information

### Easy/Decidable Instances (GRUNT_WORK difficulty):
- **Instance #2** (1320534739230343): Go - "Optimize self references"
- **Instance #3** (576003528906636): Python/mypy - "Reword error message"
- **Instance #100** (1702320040464452): Rust - "Clarify error message"

### Moderate Instances:
- **Instance #1** (1841270650076475): Go - "Use v2 Source endpoint"
- Most other instances (50-100): Various repositories

## Output Locations

All outputs are saved with timestamps in the session ID:

```
/home/ec2-user/VeloraTrajectories/outputs/
├── logs/session_TIMESTAMP/           # Detailed execution logs
├── trajectories/session_TIMESTAMP/   # Generated trajectories
├── progress/session_TIMESTAMP/       # Progress tracking files
└── results/session_TIMESTAMP/        # Final results and summaries
```

## Quick Test Examples

### Test with One Instance (Fastest)
```bash
# The script will prompt you through:
./run_instance_wise_trajectories.sh

# Then select:
# Instance Selection: 1 (Single Instance)
# Choose: 3 (Python/mypy instance)
# Execution Mode: 1 (Sequential)
# This will run all 4 models on one instance sequentially
```

### Test with 10 Instances
```bash
./run_instance_wise_trajectories.sh

# Then select:
# Instance Selection: 3 (Custom Number)
# Enter: 10
# Execution Mode: 3 (Sequential Models, Parallel Instances)
```

### Full Production Run
```bash
./run_instance_wise_trajectories.sh

# Then select:
# Instance Selection: 2 (All Instances)
# Execution Mode: 3 (Sequential Models, Parallel Instances)
```

## Monitoring Progress

During execution, check:
- Real-time logs: `tail -f /home/ec2-user/VeloraTrajectories/outputs/logs/session_*/main.log`
- Progress files: `ls /home/ec2-user/VeloraTrajectories/outputs/progress/session_*/*.status`
- Instance completion: `grep -c SUCCESS /home/ec2-user/VeloraTrajectories/outputs/progress/session_*/*.status`

## Tips

1. **Start Small**: Always test with 1 instance before running all instances
2. **Check Logs**: Monitor the log files to catch issues early
3. **Resource Management**: Use Mode 3 for best balance of speed and stability
4. **Temperature**: All models are configured with temperature=1.0 for diverse trajectories
5. **Timeouts**: Each instance has a 2-hour timeout

## Troubleshooting

### Script fails at validation
- Check Docker is running: `docker info`
- Verify dataset exists: `ls -lh data/repomate_75_samples.jsonl`

### Instance not found
- Verify instance ID exists: `jq -r '.instance_id' data/repomate_75_samples.jsonl | grep YOUR_ID`

### Out of resources
- Reduce parallel instances: Use Mode 1 (Sequential)
- Process fewer instances: Use Custom Number option

## Alternative: Simple Test Script

For quick single-instance tests, use the standalone test script:

```bash
# Test with recommended instance
./test_single.sh 576003528906636 opus

# Test with instance #100
./test_single.sh 1702320040464452 opus

# Test with different model
./test_single.sh 576003528906636 gpt
```

## Support

- Check config: `cat config.toml`
- View available instances: `jq -r '.instance_id' data/repomate_75_samples.jsonl | head -20`
- Check prerequisites: Run the script - it validates automatically
