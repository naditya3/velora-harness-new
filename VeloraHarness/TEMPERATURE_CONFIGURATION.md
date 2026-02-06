# Temperature Configuration Guide

## Overview

All models in the VeloraHarness system are configured with **temperature = 1.0** to ensure maximum diversity and exploration in trajectory generation.

## What is Temperature?

Temperature controls the randomness of model outputs:
- **0.0**: Completely deterministic (always picks highest probability token)
- **1.0**: Balanced randomness (recommended for diverse trajectories)
- **2.0**: Maximum randomness (may produce incoherent outputs)

## Current Configuration

### ✅ All Models Set to 1.0

```toml
[llm.opus]
temperature = 1.0

[llm.sonnet]
temperature = 1.0

[llm.gpt]
temperature = 1.0

[llm.kimi]
temperature = 1.0

[llm.qwen]
temperature = 1.0

[llm.gemini]
temperature = 1.0
```

## Why Temperature = 1.0?

### Benefits

✅ **Diverse Trajectories**: Each run produces different solution paths
✅ **Better Exploration**: Models explore multiple approaches
✅ **Realistic Behavior**: Mirrors how developers actually solve problems
✅ **Pass@k Evaluation**: Enables proper pass@k metrics (e.g., pass@8)
✅ **Creative Solutions**: Discovers non-obvious solutions

### Comparison

| Temperature | Behavior | Best For |
|-------------|----------|----------|
| 0.0 | Deterministic | Reproducibility, debugging |
| 0.7 | Slightly creative | Balanced tasks |
| **1.0** | **Balanced exploration** | **Trajectory generation** |
| 1.5 | Very creative | Brainstorming |

## Verification

### Check Current Settings

```bash
# Verify all models have temperature=1.0
./verify_temperature.sh
```

Output:
```
✓ opus: temperature=1.0
✓ sonnet: temperature=1.0
✓ gpt: temperature=1.0
✓ kimi: temperature=1.0
✓ qwen: temperature=1.0
✓ gemini: temperature=1.0

✅ All models have correct temperature setting: 1.0
```

### Auto-Verification on Startup

The instance-wise trajectory script automatically verifies temperature:

```bash
./run_instance_wise_trajectories.sh
```

Output includes:
```
[INFO] Verifying temperature settings in config.toml...
[SUCCESS] All models configured with temperature=1.0 ✓
```

## Changing Temperature (If Needed)

### Method 1: Manual Edit

Edit [config.toml](config.toml):

```toml
[llm.opus]
temperature = 1.0  # Change this value
```

### Method 2: Verification Script

```bash
# Set all models to 0.7
./verify_temperature.sh --set 0.7

# Fix any incorrect values back to 1.0
./verify_temperature.sh --fix
```

### Method 3: Per-Model Override

To override temperature for a specific model without changing config:

```bash
# Set environment variable (if supported by your harness)
export LLM_TEMPERATURE_OVERRIDE=0.7
./run_instance_wise_trajectories.sh
```

## Impact on Results

### Temperature = 1.0 (Current)

**Example Run 1:**
```
Instance 12345: Uses Solution Approach A (regex parsing)
Result: SUCCESS in 45 steps
```

**Example Run 2:**
```
Instance 12345: Uses Solution Approach B (AST manipulation)
Result: SUCCESS in 38 steps
```

**Example Run 3:**
```
Instance 12345: Uses Solution Approach C (string splitting)
Result: FAILED (timeout)
```

**Pass@3 = 2/3 = 66.7%** ← Valuable diversity metric!

### Temperature = 0.0 (Hypothetical)

**All Runs:**
```
Instance 12345: Always uses same Solution Approach A
Result: All runs identical
```

**Pass@3 = 1/1 = 100%** ← But no diversity information!

## Best Practices

### For Trajectory Generation

✅ **Use temperature=1.0**
- Generates diverse trajectories
- Enables proper pass@k evaluation
- Discovers multiple solution approaches

### For Debugging

If you need reproducibility for debugging:

```bash
# Temporarily set to 0 for specific instance
./verify_temperature.sh --set 0
./run_instance_wise_trajectories.sh  # Mode 4, select one instance
./verify_temperature.sh --fix         # Restore to 1.0
```

### For Production Evaluation

**Recommended**: Keep temperature=1.0 for all production runs
- Better statistical significance
- More realistic evaluation
- Captures model's full capabilities

## Monitoring Temperature

### During Execution

Check logs for temperature confirmation:

```bash
tail -f /home/ec2-user/VeloraTrajectories/outputs/logs/session_*/main.log | grep -i temperature
```

### After Execution

Verify in trajectory metadata:

```bash
# Check trajectory output for temperature setting
jq '.metadata.llm_config.temperature' \
    /home/ec2-user/VeloraTrajectories/outputs/trajectories/session_*/opus/instance_*/output.jsonl
```

## Troubleshooting

### Issue: Non-Deterministic Results

**This is expected** with temperature=1.0!

✅ **Not a bug**: Different runs should produce different trajectories
✅ **By design**: Enables proper pass@k evaluation
✅ **Solution**: Run multiple times (pass@8, pass@16, etc.)

### Issue: Want Reproducibility

**Solution**: Lower temperature for specific debugging needs

```bash
./verify_temperature.sh --set 0
# Run your test
./verify_temperature.sh --fix  # Restore to 1.0
```

### Issue: All Runs Identical

**Problem**: Temperature might not be 1.0

**Solution**: Verify and fix

```bash
./verify_temperature.sh
./verify_temperature.sh --fix
```

## Technical Details

### How Temperature Works

```python
# Simplified temperature application
def apply_temperature(logits, temperature):
    # Scale logits by temperature
    scaled_logits = logits / temperature

    # Convert to probabilities
    probabilities = softmax(scaled_logits)

    # Sample from distribution
    return sample(probabilities)
```

### Temperature Effects

```
Original Logits: [2.0, 1.5, 1.0, 0.5]

Temperature = 0.1 (near-deterministic):
Probabilities: [0.95, 0.04, 0.01, 0.00]
→ Almost always picks first token

Temperature = 1.0 (balanced):
Probabilities: [0.42, 0.28, 0.19, 0.11]
→ Balanced sampling

Temperature = 2.0 (high randomness):
Probabilities: [0.30, 0.26, 0.23, 0.21]
→ Nearly uniform sampling
```

## Configuration Files Reference

### Main Config: config.toml

Location: `/home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness/config.toml`

All model temperature settings are here.

### Verification Script: verify_temperature.sh

Location: `/home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness/verify_temperature.sh`

Automated checking and fixing of temperature settings.

### Main Script: run_instance_wise_trajectories.sh

Location: `/home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness/run_instance_wise_trajectories.sh`

Auto-verifies temperature on startup.

## Summary

✅ **All models configured with temperature=1.0**
✅ **Automatic verification on startup**
✅ **Verification script available for manual checks**
✅ **Ensures diverse trajectory generation**
✅ **Enables proper pass@k evaluation**

**No action needed** - system is already configured correctly!

To verify anytime:
```bash
./verify_temperature.sh
```

---

*Last Updated: 2026-02-06*
*Author: Expert Coder*
