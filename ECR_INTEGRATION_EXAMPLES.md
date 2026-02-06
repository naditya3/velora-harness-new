# ECR Integration Examples

Real-world examples of integrating ECR image access into your Velora Trajectories workflow.

## Example 1: Pre-flight Check Before Running Evaluations

Add this to the beginning of your evaluation scripts:

```bash
#!/bin/bash

# Ensure ECR access before running evaluations
echo "Checking ECR access..."
if ! ./setup_ecr_access.sh verify > /dev/null 2>&1; then
    echo "ECR authentication required..."
    ./setup_ecr_access.sh auth || exit 1
fi

# Now run your evaluation
python jaeger/VeloraHarness/evaluation/velora3_eval_multilang.py "$@"
```

## Example 2: Python Integration

```python
#!/usr/bin/env python3
import subprocess
import sys

def ensure_ecr_authenticated():
    """Ensure ECR is authenticated before pulling images"""
    print("Checking ECR authentication...")

    # Check if already authenticated
    result = subprocess.run(
        ["./setup_ecr_access.sh", "verify"],
        capture_output=True,
        text=True
    )

    if result.returncode != 0:
        print("Authenticating with ECR...")
        result = subprocess.run(
            ["./setup_ecr_access.sh", "auth"],
            capture_output=True,
            text=True
        )

        if result.returncode != 0:
            print("ECR authentication failed!", file=sys.stderr)
            sys.exit(1)

    print("ECR authentication verified ✓")

def pull_required_image(image_uri):
    """Pull a specific Docker image from ECR"""
    ensure_ecr_authenticated()

    print(f"Pulling image: {image_uri}")
    result = subprocess.run(
        ["docker", "pull", image_uri],
        capture_output=True,
        text=True
    )

    if result.returncode == 0:
        print(f"Successfully pulled: {image_uri}")
        return True
    else:
        print(f"Failed to pull: {image_uri}", file=sys.stderr)
        return False

# Example usage
if __name__ == "__main__":
    image = "004669175958.dkr.ecr.us-east-1.amazonaws.com/repomate_image_activ_builtin/astral-sh_uv:bd03243dd58e2ca53e919c2355a6fca929121fb7"
    pull_required_image(image)
```

## Example 3: Auto-Pull Images Based on Task Configuration

```python
#!/usr/bin/env python3
import csv
import json
from pathlib import Path

def get_required_images_for_task(task_file):
    """Extract required Docker images from a task configuration"""
    with open(task_file, 'r') as f:
        task_data = json.load(f)

    # Assuming task has an 'image' or 'docker_image' field
    return task_data.get('image') or task_data.get('docker_image')

def get_ecr_uri_from_internal(internal_uri, mapping_file='image_mapping.csv'):
    """Convert internal URI to ECR URI using mapping file"""
    with open(mapping_file, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row['internal_uri'] == internal_uri:
                return row['ecr_uri']
    return None

def prepare_images_for_tasks(task_dir):
    """Pull all required images for tasks in a directory"""
    from ecr_image_manager import ECRImageManager

    manager = ECRImageManager()
    manager.authenticate()
    manager.load_image_mapping()

    task_files = Path(task_dir).glob('**/*.json')

    for task_file in task_files:
        internal_uri = get_required_images_for_task(task_file)

        if internal_uri:
            ecr_uri = manager.image_mapping.get(internal_uri)
            if ecr_uri:
                print(f"Task: {task_file.name}")
                print(f"  Pulling: {ecr_uri}")
                manager.pull_image(ecr_uri)
            else:
                print(f"Warning: No mapping found for {internal_uri}")

# Example usage
if __name__ == "__main__":
    prepare_images_for_tasks("./tasks")
```

## Example 4: Batch Processing with Progress Tracking

```python
#!/usr/bin/env python3
from ecr_image_manager import ECRImageManager
import time

def pull_images_with_progress(max_images=None):
    """Pull images with detailed progress tracking"""
    manager = ECRImageManager()

    # Authenticate
    print("Step 1/4: Authenticating with ECR...")
    if not manager.authenticate():
        print("❌ Authentication failed")
        return

    print("✓ Authenticated\n")

    # Load mappings
    print("Step 2/4: Loading image mappings...")
    if not manager.load_image_mapping():
        print("❌ Failed to load mappings")
        return

    print(f"✓ Loaded {len(manager.image_mapping)} mappings\n")

    # Pull images
    print("Step 3/4: Pulling images...")
    images = list(manager.image_mapping.values())

    if max_images:
        images = images[:max_images]

    successful = 0
    failed = 0
    start_time = time.time()

    for idx, image in enumerate(images, 1):
        print(f"\n[{idx}/{len(images)}] {image}")

        if manager.pull_image(image):
            successful += 1
            print("  ✓ Success")
        else:
            failed += 1
            print("  ❌ Failed")

    # Summary
    elapsed = time.time() - start_time
    print(f"\nStep 4/4: Summary")
    print(f"  Total: {len(images)}")
    print(f"  Successful: {successful}")
    print(f"  Failed: {failed}")
    print(f"  Time: {elapsed:.1f}s")
    print(f"  Avg: {elapsed/len(images):.1f}s per image")

if __name__ == "__main__":
    pull_images_with_progress(max_images=10)
```

## Example 5: Integration with Existing SWE-bench Scripts

Modify your existing `pull_all_eval_docker.sh`:

```bash
#!/usr/bin/env bash
set -e

# Add ECR authentication at the beginning
echo "Authenticating with ECR..."
./setup_ecr_access.sh auth || exit 1

# Original script logic
SET=$1
if [ "$SET" != "full" ] && [ "$SET" != "lite" ] && [ "$SET" != "verified" ]; then
    echo "Error: argument 1 must be one of: full, lite, verified"
    exit 1
fi

input_file=evaluation/benchmarks/swe_bench/scripts/docker/all-swebench-${SET}-instance-images.txt
echo "Downloading images based on ${input_file}"

if [ ! -f "$input_file" ]; then
    echo "Error: File '$input_file' not found"
    exit 1
fi

# Use Python manager for better error handling
python3 ecr_image_manager.py pull-from-file "$input_file"
```

## Example 6: Periodic Token Refresh

Create a background service to keep ECR tokens fresh:

```bash
#!/bin/bash
# File: ecr_token_refresh.sh

LOG_FILE="/tmp/ecr_token_refresh.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while true; do
    echo "[$(date)] Refreshing ECR token..." >> "$LOG_FILE"

    if cd "$SCRIPT_DIR" && ./setup_ecr_access.sh auth >> "$LOG_FILE" 2>&1; then
        echo "[$(date)] Token refreshed successfully" >> "$LOG_FILE"
    else
        echo "[$(date)] Token refresh failed" >> "$LOG_FILE"
    fi

    # Sleep for 10 hours (tokens expire after 12 hours)
    sleep 36000
done
```

Run in background:
```bash
chmod +x ecr_token_refresh.sh
nohup ./ecr_token_refresh.sh &
```

## Example 7: Docker Compose Integration

```yaml
# docker-compose.yml
version: '3.8'

services:
  evaluation:
    image: 004669175958.dkr.ecr.us-east-1.amazonaws.com/repomate_image_activ_builtin/astral-sh_uv:bd03243dd58e2ca53e919c2355a6fca929121fb7
    volumes:
      - ./data:/data
    environment:
      - AWS_REGION=us-east-1
    command: python run_evaluation.py

  # Add more services as needed
```

Before running:
```bash
# Authenticate and pull
./setup_ecr_access.sh auth
docker-compose pull
docker-compose up
```

## Example 8: Pre-commit Hook

Ensure images are available before committing:

```bash
#!/bin/bash
# File: .git/hooks/pre-commit

# Check if required images are available
required_images=(
    "004669175958.dkr.ecr.us-east-1.amazonaws.com/repomate_image_activ_builtin/astral-sh_uv:bd03243dd58e2ca53e919c2355a6fca929121fb7"
)

for image in "${required_images[@]}"; do
    if ! docker image inspect "$image" > /dev/null 2>&1; then
        echo "Error: Required image not found: $image"
        echo "Run: ./setup_ecr_access.sh pull"
        exit 1
    fi
done

exit 0
```

## Example 9: Check and Pull on Demand

```python
#!/usr/bin/env python3
import subprocess

def get_or_pull_image(image_uri):
    """Get image from local cache or pull from ECR if not available"""

    # Check if image exists locally
    result = subprocess.run(
        ["docker", "image", "inspect", image_uri],
        capture_output=True,
        text=True
    )

    if result.returncode == 0:
        print(f"Using cached image: {image_uri}")
        return True

    # Image not found, pull from ECR
    print(f"Image not cached, pulling from ECR: {image_uri}")

    # Ensure authentication
    subprocess.run(["./setup_ecr_access.sh", "auth"], check=True)

    # Pull image
    result = subprocess.run(
        ["docker", "pull", image_uri],
        capture_output=True,
        text=True
    )

    return result.returncode == 0

# Example usage
image = "004669175958.dkr.ecr.us-east-1.amazonaws.com/repomate_image_activ_builtin/astral-sh_uv:bd03243dd58e2ca53e919c2355a6fca929121fb7"
get_or_pull_image(image)
```

## Example 10: Parallel Pulling with GNU Parallel

```bash
#!/bin/bash
# Pull multiple images in parallel for faster downloads

# Authenticate once
./setup_ecr_access.sh auth || exit 1

# Function to pull a single image
pull_image() {
    image="$1"
    echo "Pulling: $image"
    if docker pull "$image"; then
        echo "✓ Success: $image"
    else
        echo "✗ Failed: $image"
    fi
}

export -f pull_image

# Pull images in parallel (4 at a time)
tail -n +2 image_mapping.csv | cut -d',' -f2 | \
    parallel -j 4 pull_image {}
```

## Environment Variables Reference

Set these in your scripts for customization:

```bash
# ECR Configuration
export ECR_REGISTRY="004669175958.dkr.ecr.us-east-1.amazonaws.com"
export AWS_REGION="us-east-1"

# AWS Credentials (if not using aws configure)
export AWS_ACCESS_KEY_ID="your_access_key"
export AWS_SECRET_ACCESS_KEY="your_secret_key"
export AWS_SESSION_TOKEN="your_session_token"  # Optional

# Custom paths
export IMAGE_MAPPING_FILE="./image_mapping.csv"
```

## Testing Your Integration

```bash
# Test script
#!/bin/bash
set -e

echo "Testing ECR integration..."

# Test 1: Authentication
echo "Test 1: Authentication"
./setup_ecr_access.sh auth || exit 1
echo "✓ Pass"

# Test 2: Verification
echo "Test 2: Verification"
./setup_ecr_access.sh verify || exit 1
echo "✓ Pass"

# Test 3: Pull single image
echo "Test 3: Pull single image"
./setup_ecr_access.sh pull 1 || exit 1
echo "✓ Pass"

# Test 4: List images
echo "Test 4: List images"
./setup_ecr_access.sh list || exit 1
echo "✓ Pass"

echo "All tests passed! ✓"
```

## Monitoring and Logging

```python
#!/usr/bin/env python3
import logging
from datetime import datetime

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(f'ecr_pulls_{datetime.now():%Y%m%d}.log'),
        logging.StreamHandler()
    ]
)

logger = logging.getLogger(__name__)

# Your ECR operations with logging
from ecr_image_manager import ECRImageManager

manager = ECRImageManager()
logger.info("Starting ECR operations")

if manager.authenticate():
    logger.info("Authentication successful")
    successful, total = manager.pull_all_mapped_images(max_images=5)
    logger.info(f"Pulled {successful}/{total} images")
else:
    logger.error("Authentication failed")
```

## Best Practices

1. **Always authenticate before pulling**: Don't assume you're already authenticated
2. **Handle token expiration**: Re-authenticate if pulls fail
3. **Log operations**: Keep track of what images were pulled and when
4. **Verify before starting**: Check ECR access before long-running operations
5. **Use parallel pulling**: Speed up bulk operations with parallel downloads
6. **Cache checks**: Don't re-pull images that are already available locally
7. **Error handling**: Always handle authentication and pull failures gracefully
8. **Monitor token age**: Refresh tokens before they expire (12 hour lifetime)

## Production Deployment Checklist

- [ ] AWS credentials properly configured
- [ ] IAM permissions verified
- [ ] ECR authentication tested
- [ ] Image pulls working
- [ ] Error handling implemented
- [ ] Logging configured
- [ ] Token refresh automated (cron/systemd)
- [ ] Scripts added to version control
- [ ] Documentation updated
- [ ] Team trained on usage
