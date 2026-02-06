# Image Mapping & ECR Integration Summary

## What Was Integrated

I've successfully integrated the ECR image mapping and repository name sanitization into your VeloraHarness. Here's what was added:

### 1. **Image Utilities Module**
[`jaeger/VeloraHarness/evaluation/utils/image_utils.py`](jaeger/VeloraHarness/evaluation/utils/image_utils.py)

Provides three core functions:
- `sanitize_ecr_repo_name()` - Cleans repo names to comply with AWS ECR rules
- `translate_image_uri()` - Maps internal URIs to ECR URIs using the CSV
- `preload_image_mapping()` - Loads the CSV once for efficient lookups

### 2. **Updated Main Evaluation Script**
[`jaeger/VeloraHarness/evaluation/benchmarks/multi_swe_bench/run_infer.py`](jaeger/VeloraHarness/evaluation/benchmarks/multi_swe_bench/run_infer.py)

**Changes:**
- Added imports for image utilities
- Modified `get_instance_docker_image()` to automatically translate URIs
- Added preload call in `__main__` to load mappings at startup
- Now handles `image_storage_uri`, `task_specific_image`, and `monolith_image` fields

### 3. **Image Mapping CSV**
[`image_mapping.csv`](image_mapping.csv)

Contains 297 URI mappings from internal registry to ECR:
```csv
internal_uri,ecr_uri
vmvm-registry.fbinfra.net/...,004669175958.dkr.ecr.us-east-1.amazonaws.com/...
```

### 4. **Documentation & Tests**
- [`IMAGE_MAPPING_README.md`](jaeger/VeloraHarness/IMAGE_MAPPING_README.md) - Complete usage guide
- [`test_image_mapping.py`](test_image_mapping.py) - Integration test script

## How It Works

### Automatic Translation Flow

```
Dataset → run_infer.py → get_instance_docker_image()
                              ↓
                         translate_image_uri()
                              ↓
                         ECR URI → Docker Pull
```

### Example

**Before Integration:**
```python
# Dataset has internal URI
image_uri = "vmvm-registry.fbinfra.net/repomate_image_activ_builtin/astral-sh_uv:bd03243..."
# Would fail to pull (internal registry not accessible)
```

**After Integration:**
```python
# Automatically translated to ECR
image_uri = "004669175958.dkr.ecr.us-east-1.amazonaws.com/repomate_image_activ_builtin/astral-sh_uv:bd03243..."
# Successfully pulls from ECR
```

## Usage

### Standard Usage

No changes needed! Just run your evaluation as usual:

```bash
python3 jaeger/VeloraHarness/evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent-cls CodeActAgent \
    --llm-config llm.gemini \
    --dataset data/tasks.jsonl \
    --split train \
    --max-iterations 50 \
    --eval-num-workers 1
```

The harness will automatically:
1. Load the 297 image mappings at startup
2. Translate any internal URIs to ECR URIs
3. Sanitize ECR repo names if needed

### Custom Mapping Location

If you move `image_mapping.csv`:

```bash
export IMAGE_MAPPING_CSV=/path/to/custom/mapping.csv
python3 jaeger/VeloraHarness/evaluation/benchmarks/multi_swe_bench/run_infer.py ...
```

### Docker Usage

Update [`run_with_docker.sh`](run_with_docker.sh) to mount the CSV:

```bash
docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v $(pwd):/workspace \
    -v $(pwd)/image_mapping.csv:/workspace/image_mapping.csv \
    -e PYTHONPATH=/workspace/jaeger/VeloraHarness \
    -e IMAGE_MAPPING_CSV=/workspace/image_mapping.csv \
    velora-test \
    python3 /workspace/jaeger/VeloraHarness/evaluation/benchmarks/multi_swe_bench/run_infer.py \
        --agent-cls CodeActAgent \
        --llm-config llm.gemini \
        --max-iterations 50 \
        --eval-num-workers 1 \
        --dataset /workspace/jaeger/VeloraHarness/data/gemini_test.jsonl \
        --split train \
        --eval-n-limit 1 \
        --eval-output-dir /workspace/outputs/gemini_test
```

## Testing

Verify the integration works:

```bash
python3 test_image_mapping.py
```

**Expected output:**
```
✓ All tests completed
```

The test verifies:
- ✓ ECR name sanitization (removes double underscores, lowercases, etc.)
- ✓ Image mapping loading (297 mappings from CSV)
- ✓ URI translation (internal → ECR)

## What Gets Logged

When running evaluations, you'll see:

```
INFO: Preloaded 297 image URI mappings for ECR translation
INFO: Using image_storage_uri from dataset: vmvm-registry.fbinfra.net/...
INFO: Translated image_storage_uri to ECR: 004669175958.dkr.ecr.us-east-1.amazonaws.com/...
```

## Benefits

1. **Automatic** - No manual URI management needed
2. **Efficient** - CSV loaded once, O(1) lookups per task
3. **Flexible** - Works with any image field in the dataset
4. **Safe** - Sanitizes ECR repo names automatically
5. **Transparent** - Detailed logging shows what's being translated

## Next Steps

1. **Test with Real Data**: Run an evaluation with a dataset containing internal URIs
2. **Monitor Logs**: Verify URIs are being translated correctly
3. **Update Datasets**: Ensure your task datasets include `image_storage_uri` fields
4. **ECR Authentication**: Make sure your Docker is authenticated to pull from ECR:
   ```bash
   aws ecr get-login-password --region us-east-1 | \
       docker login --username AWS --password-stdin 004669175958.dkr.ecr.us-east-1.amazonaws.com
   ```

## Files Modified/Created

### Created:
- `jaeger/VeloraHarness/evaluation/utils/image_utils.py` (new module)
- `jaeger/VeloraHarness/IMAGE_MAPPING_README.md` (documentation)
- `test_image_mapping.py` (test script)
- `INTEGRATION_SUMMARY.md` (this file)

### Modified:
- `jaeger/VeloraHarness/evaluation/benchmarks/multi_swe_bench/run_infer.py`
  - Added image_utils imports
  - Updated `get_instance_docker_image()` function
  - Added mapping preload at startup

### Used (Not Modified):
- `image_mapping.csv` (297 URI mappings)
- `sanitize_ecr_repo_name.py` (incorporated into image_utils.py)

## Questions?

See [`IMAGE_MAPPING_README.md`](jaeger/VeloraHarness/IMAGE_MAPPING_README.md) for detailed documentation and troubleshooting.
