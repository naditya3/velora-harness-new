# Evaluation Scripts Quick Comparison

## TL;DR - Which Script Should I Use?

```
┌─────────────────────────────────────────────────────────┐
│  Do you have the Docker image locally?                 │
│  ├─ YES → run_full_eval_local_docker.sh ✅             │
│  └─ NO                                                  │
│     ├─ Have S3 access? → run_full_eval_with_s3.sh      │
│     └─ No S3 access? → Build image first, then local   │
└─────────────────────────────────────────────────────────┘
```

## Feature Matrix

| Feature | local_docker.sh | with_s3.sh | Status |
|---------|----------------|------------|--------|
| **Trajectory Generation** | ✅ | ✅ | Identical |
| **Patch Evaluation** | ✅ | ✅ | Identical |
| **Report Generation** | ✅ | ✅ | Identical |
| **Docker Download** | ❌ | ✅ S3 | Main difference |
| **Image Verification** | Interactive prompt | Auto-download | Different approach |
| **AWS Credentials** | Not required | Required | - |
| **Offline Operation** | ✅ | ❌ | - |
| **Speed (re-runs)** | Fast | Slower (download) | - |
| **Use Case** | Development | Production/CI | - |

## Side-by-Side Comparison

### run_full_eval_with_s3.sh

**Purpose**: Complete evaluation with automatic S3 Docker image download

**When to use**:
- First time evaluating a task
- Running on AWS/cloud
- CI/CD pipelines
- Don't have local images

**Workflow**:
1. Extract image info from dataset
2. **Download Docker image from S3**
3. **Load Docker image from tar**
4. Tag image for OpenHands
5. Generate trajectory
6. Evaluate patch
7. Create reports

**Key Code**:
```bash
# Downloads from S3
aws s3 cp "$S3_PATH" "$S3_IMAGE_FILE"
docker load < "$S3_IMAGE_FILE"
rm -f "$S3_IMAGE_FILE"
```

### run_full_eval_local_docker.sh

**Purpose**: Complete evaluation using locally available Docker images

**When to use**:
- Images already built/loaded
- Iterative development
- Multiple evaluations
- Offline environments

**Workflow**:
1. Extract image info from dataset
2. **Verify local Docker image exists**
3. **Prompt user if missing**
4. Tag image for OpenHands
5. Generate trajectory
6. Evaluate patch
7. Create reports

**Key Code**:
```bash
# Checks local images
if docker images --format "..." | grep -q "^${IMAGE_URI}$"; then
  echo "✓ Docker image found locally"
else
  echo "WARNING: Image not found"
  read -p "Continue anyway? (y/N)"
fi
```

## Code Difference Summary

The scripts are **99% identical**. The only difference is in lines 99-186 (S3) vs 99-177 (local):

### Lines Unique to S3 Version

```bash
# Download and load from S3
echo "Downloading from S3..."
aws s3 cp "$S3_PATH" "$S3_IMAGE_FILE"
docker load < "$S3_IMAGE_FILE"
rm -f "$S3_IMAGE_FILE"
```

### Lines Unique to Local Version

```bash
# Verify local image
if docker images ... | grep -q "^${IMAGE_URI}$"; then
  echo "✓ Found locally"
else
  echo "WARNING: Not found"
  read -p "Continue anyway? (y/N)"
fi
```

### Everything Else

**Identical** in both scripts:
- Environment variable setup
- Argument parsing and validation
- Image tagging logic
- Trajectory generation (run_infer.py)
- Patch evaluation (eval_pilot2_standardized.py)
- Report post-processing
- Output structure

## Quick Reference Commands

### Using Local Docker Script

```bash
# Basic usage
./run_full_eval_local_docker.sh llm.gpt data/task.jsonl

# With custom parameters
./run_full_eval_local_docker.sh llm.claude data/task.jsonl 1 50 1

# Check if image exists first
docker images | grep mswebench
```

### Using S3 Script

```bash
# Basic usage (downloads automatically)
./run_full_eval_with_s3.sh llm.gpt data/task.jsonl

# With custom parameters
./run_full_eval_with_s3.sh llm.claude data/task.jsonl 1 50 1

# Verify S3 access first
aws s3 ls s3://kuberha-velora/velora-files/images/
```

## Migration Guide

### From S3 to Local Docker

If you've been using the S3 script and want to switch to local:

1. **One-time setup**: Download and keep the images
   ```bash
   # Extract image name from dataset
   IMAGE_URI=$(cat task.jsonl | jq -r '.image_storage_uri')

   # Download and load once
   ./run_full_eval_with_s3.sh llm.gpt task.jsonl

   # Image is now cached locally
   docker images | grep "$IMAGE_URI"
   ```

2. **Use local script for subsequent runs**
   ```bash
   ./run_full_eval_local_docker.sh llm.gpt task.jsonl
   ```

### From Local Docker to S3

If you need to switch to S3 (e.g., moving to cloud):

```bash
# Just use the S3 script - it handles everything
./run_full_eval_with_s3.sh llm.gpt task.jsonl
```

No migration needed - S3 script is self-contained.

## Performance Comparison

Based on typical usage:

| Scenario | S3 Script | Local Script | Winner |
|----------|-----------|--------------|--------|
| First run (no cache) | ~5 min (download) + eval | Error (no image) | S3 |
| Second run (cached) | ~5 min (re-download) + eval | eval only | Local |
| 10 runs same task | ~50 min total | eval only | **Local** |
| New task each time | ~5 min each | N/A | S3 |
| Offline | ❌ Fails | ✅ Works | **Local** |

## Troubleshooting Differences

### S3 Script Issues

**Problem**: "Failed to download from S3"
```bash
# Check credentials
aws sts get-caller-identity

# Check S3 access
aws s3 ls s3://kuberha-velora/velora-files/images/
```

**Problem**: "Failed to load Docker image"
```bash
# Check disk space
df -h

# Check tar file
ls -lh *.tar
file *.tar
```

### Local Script Issues

**Problem**: "Docker image not found"
```bash
# Option 1: Use S3 script once
./run_full_eval_with_s3.sh llm.gpt task.jsonl

# Option 2: Load manually
docker load < image.tar

# Option 3: Build the image
# (Follow SWE-bench Docker build guide)
```

**Problem**: "Continue anyway? (y/N)"
```bash
# This is interactive - answer 'y' or 'n'
# Or add auto-yes:
yes y | ./run_full_eval_local_docker.sh ...
```

## Best Practices

### For Development

```bash
# First run: use S3 to get the image
./run_full_eval_with_s3.sh llm.gpt task.jsonl

# Subsequent runs: use local for speed
./run_full_eval_local_docker.sh llm.gpt task.jsonl
```

### For Production/CI

```bash
# Always use S3 for reproducibility
./run_full_eval_with_s3.sh llm.gpt task.jsonl
```

### For Batch Processing

```bash
# Download all images once (S3)
for task in tasks/*.jsonl; do
  ./run_full_eval_with_s3.sh llm.gpt "$task" 1 5 1
done

# Then run full evals (local)
for task in tasks/*.jsonl; do
  ./run_full_eval_local_docker.sh llm.gpt "$task" 1 30 1
done
```

## Output Differences

**None** - Both scripts produce identical output structures:

```
eval_outputs/
└── {instance_id}/
    ├── report.json        # Identical format
    ├── patch.diff         # Identical content
    ├── test_output.txt    # Identical test output
    └── run_instance.log   # Identical logs
```

The reports are **100% compatible** and can be used interchangeably.

## Summary

| Aspect | Recommendation |
|--------|----------------|
| **Development** | Use local_docker.sh |
| **CI/CD** | Use with_s3.sh |
| **First time** | Use with_s3.sh |
| **Iterations** | Use local_docker.sh |
| **Offline** | Use local_docker.sh |
| **Reproducibility** | Both are equivalent |
| **Speed** | local_docker.sh (after first run) |

**Bottom line**: Both scripts are production-ready and produce identical results. Choose based on your workflow:
- **S3**: Convenience, automation, first-time setup
- **Local**: Speed, offline access, iterative development
