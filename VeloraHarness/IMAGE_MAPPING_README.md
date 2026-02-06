# Image Mapping and ECR Integration

This document describes how the VeloraHarness integrates with ECR (Amazon Elastic Container Registry) using image URI mapping and repository name sanitization.

## Overview

The harness now supports automatic translation of internal Docker registry URIs to AWS ECR URIs, along with automatic sanitization of ECR repository names to comply with AWS naming rules.

## Components

### 1. Image Mapping CSV (`image_mapping.csv`)

Located at the project root, this CSV file maps internal registry URIs to ECR URIs:

```csv
internal_uri,ecr_uri
vmvm-registry.fbinfra.net/repo/image:tag,004669175958.dkr.ecr.us-east-1.amazonaws.com/repo/image:tag
```

### 2. Image Utils Module (`evaluation/utils/image_utils.py`)

Provides three main functions:

- **`sanitize_ecr_repo_name(name)`**: Sanitizes repository names according to ECR rules
  - Converts to lowercase
  - Removes double underscores
  - Replaces invalid characters with hyphens
  - Removes leading/trailing special characters

- **`translate_image_uri(image_uri)`**: Translates internal URIs to ECR URIs using the mapping

- **`preload_image_mapping(csv_path)`**: Preloads the mapping CSV for efficient lookups

### 3. Integration in `run_infer.py`

The main evaluation script automatically:
1. Preloads the image mapping at startup
2. Translates all image URIs (from `image_storage_uri`, `task_specific_image`, `monolith_image` fields)
3. Sanitizes ECR repository names when needed

## Usage

### Basic Usage

The integration works automatically. Just ensure `image_mapping.csv` is in the project root:

```bash
python jaeger/VeloraHarness/evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent-cls CodeActAgent \
    --llm-config llm.gemini \
    --dataset data/tasks.jsonl \
    --split train
```

### Custom Mapping File Location

Set the `IMAGE_MAPPING_CSV` environment variable:

```bash
export IMAGE_MAPPING_CSV=/path/to/custom/mapping.csv

python jaeger/VeloraHarness/evaluation/benchmarks/multi_swe_bench/run_infer.py ...
```

### Docker Usage

When running in Docker, mount the mapping file:

```bash
docker run --rm \
    -v $(pwd)/image_mapping.csv:/workspace/image_mapping.csv \
    -e IMAGE_MAPPING_CSV=/workspace/image_mapping.csv \
    velora-harness \
    python3 /workspace/jaeger/VeloraHarness/evaluation/benchmarks/multi_swe_bench/run_infer.py ...
```

## How It Works

### Translation Process

1. **At Startup**: The mapping CSV is loaded into memory once
2. **During Evaluation**: For each task instance:
   - The harness reads `image_storage_uri` (or other image fields) from the dataset
   - If the URI exists in the mapping, it's translated to the ECR URI
   - The ECR repository name is sanitized if needed
   - The translated URI is used to pull the Docker image

### Example

Dataset entry:
```json
{
  "instance_id": "task-123",
  "image_storage_uri": "vmvm-registry.fbinfra.net/repomate_image/astral-sh_uv:bd03243"
}
```

Translation:
```
vmvm-registry.fbinfra.net/repomate_image/astral-sh_uv:bd03243
  ↓
004669175958.dkr.ecr.us-east-1.amazonaws.com/repomate_image/astral-sh_uv:bd03243
```

## ECR Naming Rules

ECR repository names must:
- Use lowercase letters only
- Allow: letters, numbers, hyphens, underscores, forward slashes, periods
- NOT allow: double underscores (`__`), leading/trailing special chars

The sanitization function automatically handles these rules.

## Logging

The integration provides detailed logging:

```
INFO: Preloaded 150 image URI mappings for ECR translation
INFO: Using image_storage_uri from dataset: vmvm-registry.fbinfra.net/...
INFO: Translated image_storage_uri to ECR: 004669175958.dkr.ecr.us-east-1.amazonaws.com/...
```

## Troubleshooting

### No Translation Occurring

**Symptom**: Images are not being translated to ECR URIs

**Solutions**:
1. Verify `image_mapping.csv` exists in the project root
2. Check the CSV format (must have `internal_uri` and `ecr_uri` columns)
3. Look for warnings in logs: `Image mapping file not found`
4. Verify the internal URI exactly matches an entry in the CSV

### Invalid ECR Repository Names

**Symptom**: Docker pull fails with ECR naming errors

**Solutions**:
1. The sanitization should handle this automatically
2. Check logs for: `Sanitized ECR repo name: ...`
3. Verify your `image_mapping.csv` has valid ECR URIs

### Mapping File Not Found

**Symptom**: Log shows `Image mapping file not found`

**Solutions**:
1. Ensure `image_mapping.csv` is at `/home/ec2-user/VeloraTrajectories/image_mapping.csv`
2. Or set `IMAGE_MAPPING_CSV` environment variable to the correct path
3. In Docker, mount the file into the container

## Testing

To test the integration:

```python
from evaluation.utils.image_utils import (
    sanitize_ecr_repo_name,
    translate_image_uri,
    preload_image_mapping
)

# Test sanitization
name, modified = sanitize_ecr_repo_name("Repo__Name")
print(f"{name} (modified: {modified})")  # repo_name (modified: True)

# Test translation
preload_image_mapping()
ecr_uri = translate_image_uri("vmvm-registry.fbinfra.net/repo/image:tag")
print(ecr_uri)  # 004669175958.dkr.ecr.us-east-1.amazonaws.com/repo/image:tag
```

## Performance

- **Startup**: Mapping CSV is loaded once (~0.1s for 1000 entries)
- **Per-task**: Translation is O(1) dictionary lookup (~0.0001s)
- **Memory**: Negligible (~100KB for 1000 mappings)

## Future Enhancements

Possible improvements:
1. Support for regex-based URI patterns
2. Automatic ECR authentication
3. Fallback to alternative registries
4. Dynamic mapping updates without restart
