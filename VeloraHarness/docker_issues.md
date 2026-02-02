## Summary: Trajectory Generation Process & Docker Fixes
### The Standard Process We Discovered
Based on our investigation, here's the correct workflow from **CSV to Trajectory**:
#### 1. Dataset Creation (from ClientSheet CSV)
```
ClientSheet.csv → JSONL dataset
```
Key fields needed:
- `instance_id`: Numeric ID from client
- `repo`: `owner/repo` format
- `base_commit`: Git commit hash
- `version`: Should match `instance_id` (NOT "1.0")
- `image_storage_uri`: Docker image reference
- `problem_statement`: Issue description
#### 2. Docker Image Loading (Critical Fix!)
**The Problem**: The `image_storage_uri` in the CSV points to an **internal registry** (`vmvm-registry.fbinfra.net`) that's not accessible from AWS:
```
vmvm-registry.fbinfra.net/repomate_image_activ_pytest/randovania_randovania:bd8e6fa...
```
**The Solution**: Images are pre-uploaded to **S3** with a naming convention:
| Client URI Format | S3 Path |
|-------------------|---------|
| `vmvm-registry.../owner_repo:commit` | `s3://kuberha-velora/velora-files/images/owner_repo-commit.tar` |
**Example**:
```bash
# Client image_storage_uri:
vmvm-registry.fbinfra.net/.../randovania_randovania:bd8e6fa803af7fb4c5a3bb7bb4ad4d2f5463682d
# S3 path:
s3://kuberha-velora/velora-files/images/randovania_randovania-bd8e6fa803af7fb4c5a3bb7bb4ad4d2f5463682d.tar
```
#### 3. Load Image on AWS Instance
```bash
# Download from S3
aws s3 cp s3://kuberha-velora/velora-files/images/owner_repo-commit.tar /home/ubuntu/SWETEs7/images/
# Load into Docker
docker load -i /home/ubuntu/SWETEs7/images/owner_repo-commit.tar
# Tag with SHORT name (critical for Docker FROM clause)
docker tag vmvm-registry.fbinfra.net/.../owner_repo:commit owner_repo:commit
# Delete tar to save space
rm /home/ubuntu/SWETEs7/images/owner_repo-commit.tar
```
#### 4. Update Dataset to Use Local Image Name
**Before** (won't work - Docker tries to pull from registry):
```json
{"image_storage_uri": "vmvm-registry.fbinfra.net/.../randovania_randovania:bd8e6fa..."}
```
**After** (works - Docker finds local image):
```json
{"image_storage_uri": "randovania_randovania:bd8e6fa803af7fb4c5a3bb7bb4ad4d2f5463682d"}
```
---
### Docker Fixes We Applied
#### Fix 1: Patched OpenHands to Use `image_storage_uri`
The original `multi_swe_bench/run_infer.py` was **ignoring** our `image_storage_uri` field and constructing its own image name. We patched it:
```python
# Added to get_instance_docker_image() function:
def get_instance_docker_image(instance: pd.Series):
    # FIRST: Check if image_storage_uri is provided in the dataset
    image_storage_uri = instance.get("image_storage_uri", "")
    if image_storage_uri and pd.notna(image_storage_uri) and str(image_storage_uri).strip():
        logger.info(f"Using image_storage_uri from dataset: {image_storage_uri}")
        return str(image_storage_uri).strip()
    # FALLBACK: Original logic to construct from instance_id
    ...
```
#### Fix 2: Strip Registry Prefix from Image Name
Docker's `FROM` directive in Dockerfile tries to **pull** when a full registry path is specified. Solution: tag image without registry prefix:
```bash
# This causes Docker to try pulling (fails):
FROM vmvm-registry.fbinfra.net/repomate_image_activ_pytest/randovania_randovania:commit
# This uses local image (works):
FROM randovania_randovania:commit
```
#### Fix 3: Clean Disk Space Before Building
The OpenHands runtime build requires ~10GB+ of space. We hit "no space left on device" error:
```bash
# Clean Docker cache and images
docker system prune -af --volumes
```
---
### Complete Working Command Sequence
```bash
# 1. On AWS instance - Download and load image from S3
S3_PATH="s3://kuberha-velora/velora-files/images/randovania_randovania-bd8e6fa803af7fb4c5a3bb7bb4ad4d2f5463682d.tar"
aws s3 cp "$S3_PATH" /tmp/image.tar
docker load -i /tmp/image.tar
docker tag vmvm-registry.fbinfra.net/.../randovania_randovania:bd8e6fa... randovania_randovania:bd8e6fa...
rm /tmp/image.tar
# 2. Update dataset's image_storage_uri to short name
# (edit JSONL file to use "randovania_randovania:bd8e6fa..." without registry)
# 3. Run trajectory
source ~/velora/OpenHands/openhands_venv/bin/activate
cd ~/SWETEs7/OpenHands
export USE_INSTANCE_IMAGE=true
export LANGUAGE=python
python -m evaluation.benchmarks.multi_swe_bench.run_infer \
    --llm-config llm.gpt \
    --agent-cls CodeActAgent \
    --max-iterations 300 \
    --dataset /path/to/dataset.jsonl \
    --split train \
    --eval-n-limit 1
```
---
### Key Scripts for This Process
| Script | Purpose |
|--------|---------|
| `scripts/prepare_task.py` | Converts CSV row to JSONL with S3 path derivation |
| `scripts/ec2_fetch_docker.sh` | Downloads Docker image from S3 on EC2 |
| `scripts/s3_docker_pipeline.py` | Manages S3 upload/download of Docker images |