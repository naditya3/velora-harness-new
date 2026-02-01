#!/usr/bin/env xonsh
# run_full_eval_with_s3.xsh - Complete Velora evaluation pipeline with S3 Docker download
#
# This script:
#   1. Downloads Docker image from S3 based on dataset
#   2. Loads and tags the image for OpenHands
#   3. Runs trajectory generation (run_infer.py)
#   4. Runs patch evaluation (eval_pilot2_standardized.py)
#   5. Creates OpenHands-format reports
#
# Usage: ./run_full_eval_with_s3.xsh MODEL_CONFIG DATASET [EVAL_LIMIT] [MAX_ITER] [NUM_WORKERS]
# Example: ./run_full_eval_with_s3.xsh llm.gpt data/task.jsonl 1 30 1

import sys
import json
from pathlib import Path
import subprocess

# ============================================
# VELORA-SPECIFIC ENVIRONMENT VARIABLES
# ============================================
$DOCKER_BUILDKIT = "0"                    # CRITICAL: Prevents buildx failures
$EVAL_DOCKER_IMAGE_PREFIX = "mswebench"   # Our Docker image prefix
$USE_INSTANCE_IMAGE = "true"              # Use instance-specific images
$LANGUAGE = "python"                      # Our tasks are Python
$RUN_WITH_BROWSING = "false"
$USE_HINT_TEXT = "false"

# ============================================
# ARGUMENT PARSING
# ============================================
def parse_args():
    args = sys.argv[1:]
    if len(args) < 2:
        print("ERROR: MODEL_CONFIG and DATASET are required")
        print("Usage: run_full_eval_with_s3.xsh MODEL_CONFIG DATASET [EVAL_LIMIT] [MAX_ITER] [NUM_WORKERS] [AGENT]")
        sys.exit(1)
    
    model_config = args[0]
    dataset = args[1]
    eval_limit = args[2] if len(args) > 2 else "1"
    max_iter = args[3] if len(args) > 3 else "30"
    num_workers = args[4] if len(args) > 4 else "1"
    agent = args[5] if len(args) > 5 else "CodeActAgent"
    split = "train"
    
    return model_config, dataset, eval_limit, max_iter, num_workers, agent, split

model_config, dataset, eval_limit, max_iter, num_workers, agent, split = parse_args()

# ============================================
# VALIDATION
# ============================================
dataset_path = Path(dataset)
if not dataset_path.exists():
    print(f"ERROR: Dataset file not found: {dataset}")
    sys.exit(1)

dataset_abs = str(dataset_path.absolute())

# ============================================
# DISPLAY CONFIGURATION
# ============================================
print("=" * 44)
print("VELORA FULL EVALUATION WITH S3 DOWNLOAD")
print("=" * 44)
print(f"MODEL_CONFIG: {model_config}")
print(f"DATASET: {dataset_abs}")
print(f"EVAL_LIMIT: {eval_limit}")
print(f"MAX_ITER: {max_iter}")
print(f"NUM_WORKERS: {num_workers}")
print(f"AGENT: {agent}")
print(f"SPLIT: {split}")
print()
print("Environment:")
print(f"  DOCKER_BUILDKIT: {$DOCKER_BUILDKIT}")
print(f"  EVAL_DOCKER_IMAGE_PREFIX: {$EVAL_DOCKER_IMAGE_PREFIX}")
print(f"  USE_INSTANCE_IMAGE: {$USE_INSTANCE_IMAGE}")
print(f"  LANGUAGE: {$LANGUAGE}")
print("=" * 44)
print()

# ============================================
# EXTRACT DOCKER IMAGE INFO FROM DATASET
# ============================================
print("=" * 44)
print("EXTRACTING DOCKER IMAGE INFO FROM DATASET")
print("=" * 44)

with open(dataset_abs, 'r') as f:
    dataset_data = json.load(f)

instance_id = dataset_data.get('instance_id', '')
if not instance_id:
    print("ERROR: Could not extract instance_id from dataset")
    sys.exit(1)

print(f"Instance ID: {instance_id}")

image_uri = dataset_data.get('image_storage_uri', '')
repo = dataset_data.get('repo', '')
base_commit = dataset_data.get('base_commit', '')

print(f"Image URI: {image_uri}")
print(f"Repo: {repo}")
print(f"Base Commit: {base_commit}")

# Extract language from dataset and override environment variable
task_language = dataset_data.get('language', 'python').lower()
$LANGUAGE = task_language
print(f"Language (from dataset): {task_language}")

# Construct S3 path
repo_part = image_uri.split('/')[-1]
repo_name = repo_part.split(':')[0]
commit = repo_part.split(':')[1]
s3_image_file = f"{repo_name}-{commit}.tar"
s3_path = f"s3://kuberha-velora/velora-files/images/{s3_image_file}"

print(f"S3 Path: {s3_path}")
print(f"Local file: {s3_image_file}")

# ============================================
# DOWNLOAD AND LOAD DOCKER IMAGE FROM S3
# ============================================
print()
print("=" * 44)
print("DOWNLOADING DOCKER IMAGE FROM S3")
print("=" * 44)

# Check if image already exists
existing_images = $(docker images --format "{{.Repository}}:{{.Tag}}").strip().split('\n')
if image_uri in existing_images:
    print(f"✓ Docker image already loaded: {image_uri}")
else:
    print("Downloading from S3...")
    aws s3 cp @(s3_path) @(s3_image_file)
    
    if $LASTRET != 0:
        print("ERROR: Failed to download Docker image from S3")
        sys.exit(1)
    
    file_size = $(du -h @(s3_image_file) | cut -f1).strip()
    print(f"✓ Downloaded {file_size}")
    
    print("Loading Docker image...")
    docker load < @(s3_image_file)
    
    if $LASTRET != 0:
        print("ERROR: Failed to load Docker image")
        sys.exit(1)
    
    print("✓ Image loaded")
    
    # Cleanup tar file
    rm -f @(s3_image_file)
    print("✓ Cleaned up tar file")

# ============================================
# TAG DOCKER IMAGE FOR OPENHANDS
# ============================================
print()
print("=" * 44)
print("TAGGING DOCKER IMAGE FOR OPENHANDS")
print("=" * 44)

# Double tagging as per OpenHands requirements
repo_m = repo.replace('/', '_m_')
tag1 = f"mswebench/sweb.eval.x86_64.{instance_id}:latest"
tag2 = f"mswebench/{repo_m}:pr-{instance_id}"

print(f"Original image: {image_uri}")
print(f"Tag 1: {tag1}")
print(f"Tag 2: {tag2}")

docker tag @(image_uri) @(tag1)
docker tag @(image_uri) @(tag2)

print("✓ Image tagged successfully")

# Verify tags
print()
print("Verifying tags:")
docker images | grep -E @(f"({instance_id}|{repo_m})") | head -5

# ============================================
# GET OPENHANDS VERSION
# ============================================
print()
print("=" * 44)
print("CONFIGURATION")
print("=" * 44)

openhands_version = "v1.1.0"
print(f"OPENHANDS_VERSION: {openhands_version}")

# BUILD EVAL NOTE
eval_note = f"{openhands_version}-no-hint"
if 'EXP_NAME' in ${...}:
    eval_note = f"{eval_note}-{$EXP_NAME}"
print(f"EVAL_NOTE: {eval_note}")

# ============================================
# PHASE 1: TRAJECTORY GENERATION
# ============================================
print()
print("=" * 44)
print("PHASE 1: TRAJECTORY GENERATION")
print("=" * 44)

if 'SANDBOX_ENV_GITHUB_TOKEN' in ${...}:
    del $SANDBOX_ENV_GITHUB_TOKEN  # Prevent agent from using github token

n_runs = int(${...}.get('N_RUNS', '1'))
for i in range(1, n_runs + 1):
    current_eval_note = f"{eval_note}-run_{i}"
    print()
    print(f"Starting run {i} with eval_note: {current_eval_note}")
    print()
    
    poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
        --agent-cls @(agent) \
        --llm-config @(model_config) \
        --max-iterations @(max_iter) \
        --eval-num-workers @(num_workers) \
        --eval-note @(current_eval_note) \
        --dataset @(dataset_abs) \
        --split @(split) \
        --eval-n-limit @(eval_limit)

# ============================================
# FIND OUTPUT FILE
# ============================================
print()
print("=" * 44)
print("LOCATING TRAJECTORY OUTPUT")
print("=" * 44)

# Extract model name from config
import re
model_name = "unknown"
with open('config.toml', 'r') as f:
    content = f.read()
    pattern = rf'\[{re.escape(model_config)}\].*?model\s*=\s*"([^"]*)"'
    match = re.search(pattern, content, re.DOTALL)
    if match:
        model_name = match.group(1)

print(f"Model name: {model_name}")

# Find the output directory
output_base = Path("evaluation/evaluation_outputs/outputs")

# Find most recent output.jsonl
output_files = list(output_base.rglob("output.jsonl"))
if output_files:
    # Filter by eval_note and modification time
    recent_files = []
    from datetime import datetime, timedelta
    cutoff = datetime.now() - timedelta(minutes=30)
    
    for f in output_files:
        if current_eval_note in str(f) and datetime.fromtimestamp(f.stat().st_mtime) > cutoff:
            recent_files.append(f)
    
    if not recent_files:
        # Try by iteration count
        for f in output_files:
            if f"maxiter_{max_iter}" in str(f) and datetime.fromtimestamp(f.stat().st_mtime) > cutoff:
                recent_files.append(f)
    
    if not recent_files:
        # Last resort: most recent
        recent_files = sorted([f for f in output_files 
                             if datetime.fromtimestamp(f.stat().st_mtime) > cutoff],
                             key=lambda x: x.stat().st_mtime, reverse=True)
    
    if recent_files:
        output_file = recent_files[0]
        output_dir = output_file.parent
    else:
        print("ERROR: Could not find output.jsonl!")
        sys.exit(1)
else:
    print("ERROR: Could not find output.jsonl!")
    sys.exit(1)

print(f"Found output directory: {output_dir}")
print(f"Output file: {output_file}")

if not output_file.exists():
    print(f"ERROR: Output file not found: {output_file}")
    sys.exit(1)

# ============================================
# VERIFY INSTANCE ID MATCHES
# ============================================
with open(output_file, 'r') as f:
    traj_data = json.load(f)

traj_instance_id = traj_data.get('instance_id', '')

if traj_instance_id != instance_id:
    print("WARNING: Instance ID mismatch!")
    print(f"  Dataset: {instance_id}")
    print(f"  Trajectory: {traj_instance_id}")

print(f"Instance ID verified: {instance_id}")

# ============================================
# CHECK FOR NON-EMPTY PATCHES
# ============================================
patch = traj_data.get('test_result', {}).get('git_patch', '')
patch_size = len(patch)

print(f"Git patch size: {patch_size} bytes")

if patch_size < 100:
    print("WARNING: No valid patch found in output. Skipping evaluation.")
    print()
    print("=" * 44)
    print("TRAJECTORY GENERATION COMPLETE (NO PATCH)")
    print("=" * 44)
    print(f"Output directory: {output_dir}")
    sys.exit(0)

# ============================================
# PHASE 2: DETAILED PATCH EVALUATION
# ============================================
print()
print("=" * 44)
print("PHASE 2: DETAILED PATCH EVALUATION")
print("Using eval_pilot2_standardized.py")
print("=" * 44)

# Run the detailed evaluation script
script_dir = Path(__file__).parent
eval_script = script_dir / "eval_pilot2_standardized.py"
eval_output_file = output_dir / "eval_pilot2_output.jsonl"

# Export variables for Python post-processing
$INSTANCE_ID = instance_id
$OUTPUT_DIR = str(output_dir)
$EVAL_OUTPUT_FILE = str(eval_output_file)

# Verify eval script exists
if not eval_script.exists():
    print(f"ERROR: Evaluation script not found: {eval_script}")
    print("Expected location: evaluation/benchmarks/multi_swe_bench/scripts/eval_pilot2_standardized.py")
    sys.exit(1)

# Use the mswebench tagged image
docker_image = tag1
print(f"Docker image for evaluation: {docker_image}")
print(f"Evaluation script: {eval_script}")

python3 @(eval_script) \
    --trajectory-file @(output_file) \
    --dataset-file @(dataset_abs) \
    --docker-image @(docker_image) \
    --output-file @(eval_output_file) \
    --timeout 600

if $LASTRET != 0:
    print(f"ERROR: Evaluation failed with exit code {$LASTRET}")
    sys.exit($LASTRET)

# ============================================
# POST-PROCESS: CREATE OPENHANDS-FORMAT REPORT
# ============================================
print()
print("=" * 44)
print("GENERATING OPENHANDS-FORMAT REPORT")
print("=" * 44)

# Load eval_pilot2 output
with open(eval_output_file, 'r') as f:
    eval_data = json.load(f)

details = eval_data.get('pilot2_eval_details', {})

# Create eval_outputs directory structure
eval_outputs_dir = output_dir / 'eval_outputs'
instance_eval_dir = eval_outputs_dir / instance_id
instance_eval_dir.mkdir(parents=True, exist_ok=True)

# Generate OpenHands-format report.json
report = {
    instance_id: {
        "patch_is_None": False,
        "patch_exists": True,
        "patch_successfully_applied": not details.get('failed_apply_patch', False),
        "resolved": details.get('resolved', False),
        "tests_status": {
            "FAIL_TO_PASS": {
                "success": details.get('fail_to_pass_success', []),
                "failure": details.get('fail_to_pass_failed', [])
            },
            "PASS_TO_PASS": {
                "success": details.get('pass_to_pass_success', []),
                "failure": details.get('pass_to_pass_failed', [])
            },
            "FAIL_TO_FAIL": {
                "success": [],
                "failure": []
            },
            "PASS_TO_FAIL": {
                "success": [],
                "failure": []
            }
        }
    }
}

# Save report.json in eval_outputs directory
report_file = instance_eval_dir / 'report.json'
with open(report_file, 'w') as f:
    json.dump(report, f, indent=4)

print(f"Created: {report_file}")

# Save test_output.txt
test_output_file = instance_eval_dir / 'test_output.txt'
with open(test_output_file, 'w') as f:
    f.write(details.get('test_output', ''))

print(f"Created: {test_output_file}")

# Save patch.diff
patch_file = instance_eval_dir / 'patch.diff'
with open(patch_file, 'w') as f:
    f.write(patch)

print(f"Created: {patch_file}")

# Print summary
print()
print("=" * 60)
print("EVALUATION REPORT SUMMARY")
print("=" * 60)
print(f"Instance: {instance_id}")
print(f"Resolved: {details.get('resolved', False)}")
print(f"Tests Passed: {details.get('tests_passed', 0)}")
print(f"Tests Failed: {details.get('tests_failed', 0)}")
print(f"Tests Error: {details.get('tests_error', 0)}")
f2p_success = len(details.get('fail_to_pass_success', []))
f2p_total = f2p_success + len(details.get('fail_to_pass_failed', []))
p2p_success = len(details.get('pass_to_pass_success', []))
p2p_total = p2p_success + len(details.get('pass_to_pass_failed', []))
print(f"F2P Success: {f2p_success}/{f2p_total}")
print(f"P2P Success: {p2p_success}/{p2p_total}")
print("=" * 60)

# ============================================
# SUMMARY
# ============================================
print()
print("=" * 44)
print("FULL EVALUATION COMPLETE")
print("=" * 44)
print()
print(f"Output directory: {output_dir}")
print()
print("Files generated:")
for item in output_dir.iterdir():
    print(f"  {item.name}")
print()

# Show eval_outputs structure
if eval_outputs_dir.exists():
    print("=== Evaluation Outputs ===")
    for instance_dir in eval_outputs_dir.iterdir():
        if instance_dir.is_dir():
            iid = instance_dir.name
            print(f"Instance: {iid}")
            print(f"  Files: {' '.join([f.name for f in instance_dir.iterdir()])}")
            
            report_path = instance_dir / 'report.json'
            if report_path.exists():
                print()
                print("  Report Details:")
                with open(report_path, 'r') as f:
                    rdata = json.load(f)
                    for iid, rdetails in rdata.items():
                        print(f"    Resolved: {rdetails.get('resolved', False)}")
                        print(f"    Patch Applied: {rdetails.get('patch_successfully_applied', False)}")
                        ts = rdetails.get('tests_status', {})
                        f2p = ts.get('FAIL_TO_PASS', {})
                        p2p = ts.get('PASS_TO_PASS', {})
                        print(f"    F2P Success: {len(f2p.get('success', []))} / Failure: {len(f2p.get('failure', []))}")
                        print(f"    P2P Success: {len(p2p.get('success', []))} / Failure: {len(p2p.get('failure', []))}")
            print()

print()
print("=" * 44)
print("SUCCESS: Full evaluation with S3 download complete")
print("=" * 44)
