#!/usr/bin/env xonsh
"""
Single Instance Evaluation Script (Xonsh Version)

This is the xonsh equivalent of run_full_eval_with_s3.sh.
It runs trajectory generation and evaluation for a single instance.

Usage:
    ./run_eval.xsh --model gemini --dataset /path/to/instance.jsonl
    ./run_eval.xsh --model-config llm.gemini3 --dataset /path/to/instance.jsonl --max-iter 1000
"""

import argparse
import json
import os
import sys
import subprocess
import time
import datetime
from pathlib import Path
from typing import Optional, Dict, Any, Tuple

# =============================================================================
# CONFIGURATION
# =============================================================================

$DOCKER_BUILDKIT = "1"
$EVAL_DOCKER_IMAGE_PREFIX = "mswebench"
$USE_INSTANCE_IMAGE = "true"
$LANGUAGE = "python"
$RUN_WITH_BROWSING = "false"
$USE_HINT_TEXT = "false"

MODEL_CONFIG_MAP = {
    'gemini': 'llm.gemini3',
    'claude': 'llm.claude',
    'gpt': 'llm.gpt'
}

# =============================================================================
# UTILITIES
# =============================================================================

def log(message: str, level: str = "INFO"):
    """Print timestamped log message."""
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    prefix = {"INFO": "ℹ️", "ERROR": "❌", "SUCCESS": "✅", "WARNING": "⚠️"}.get(level, "")
    print(f"[{timestamp}] {prefix} {message}")

def run_command(cmd: str, timeout: int = None, capture: bool = False) -> Tuple[int, str, str]:
    """Run a shell command and return (returncode, stdout, stderr)."""
    try:
        if capture:
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
            return result.returncode, result.stdout, result.stderr
        else:
            result = subprocess.run(cmd, shell=True, timeout=timeout)
            return result.returncode, "", ""
    except subprocess.TimeoutExpired:
        return -1, "", "Command timed out"
    except Exception as e:
        return -1, "", str(e)

def get_disk_space_gb() -> int:
    """Get available disk space in GB."""
    import shutil
    total, used, free = shutil.disk_usage("/")
    return free // (1024**3)

def get_memory_gb() -> int:
    """Get available memory in GB."""
    try:
        with open('/proc/meminfo') as f:
            for line in f:
                if 'MemAvailable' in line:
                    return int(line.split()[1]) // (1024**2)
    except:
        pass
    return 0

# =============================================================================
# DOCKER UTILITIES
# =============================================================================

def docker_image_exists(image: str) -> bool:
    """Check if Docker image exists locally."""
    cmd = f"docker images -q {image}"
    rc, stdout, _ = run_command(cmd, capture=True)
    return rc == 0 and bool(stdout.strip())

def docker_cleanup():
    """Run Docker cleanup to free resources."""
    log("Running Docker cleanup...")
    run_command("docker container prune -f 2>/dev/null")
    run_command("docker image prune -f 2>/dev/null")
    
    # Clean old OpenHands runtime images
    rc, images, _ = run_command(
        "docker images --format '{{.Repository}}:{{.Tag}}' | grep -E 'ghcr.io/openhands/runtime' | head -10",
        capture=True
    )
    if images.strip():
        for img in images.strip().split('\n'):
            run_command(f"docker rmi -f {img} 2>/dev/null")
    log("Docker cleanup complete")

def fix_docker_image_with_tmux(source_image: str, target_tag: str) -> bool:
    """Fix Docker image by installing tmux."""
    log(f"Fixing Docker image: installing tmux...")
    
    # Create temporary container
    rc, container_id, _ = run_command(
        f"docker run -d --entrypoint /bin/bash {source_image} -c 'sleep 300'",
        capture=True
    )
    if rc != 0:
        return False
    
    container_id = container_id.strip()
    
    # Install tmux
    fix_cmd = '''
cat > /etc/apt/sources.list << "EOF"
deb http://archive.ubuntu.com/ubuntu/ jammy main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ jammy-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ jammy-security main restricted universe multiverse
EOF
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
export http_proxy="" https_proxy=""
apt-get update && apt-get install -y tmux
'''
    
    rc, _, _ = run_command(f"docker exec {container_id} bash -c '{fix_cmd}'")
    
    if rc == 0:
        run_command(f"docker commit {container_id} {target_tag}")
        log(f"Fixed image committed as: {target_tag}")
    else:
        log("Failed to install tmux, using original image", "WARNING")
        run_command(f"docker tag {source_image} {target_tag}")
    
    # Cleanup
    run_command(f"docker stop {container_id} 2>/dev/null")
    run_command(f"docker rm {container_id} 2>/dev/null")
    
    return True

def load_docker_from_s3(s3_path: str, local_file: str) -> bool:
    """Download and load Docker image from S3."""
    if os.path.exists(local_file):
        log(f"Local file already exists: {local_file}")
    else:
        log(f"Downloading from S3: {s3_path}")
        rc, _, stderr = run_command(f"aws s3 cp {s3_path} {local_file} --only-show-errors")
        if rc != 0:
            log(f"Failed to download: {stderr}", "ERROR")
            return False
    
    log("Loading Docker image...")
    rc, stdout, _ = run_command(f"docker load < {local_file}", capture=True)
    if rc != 0:
        log("Failed to load Docker image", "ERROR")
        return False
    
    log("Image loaded successfully", "SUCCESS")
    return True

# =============================================================================
# DATASET UTILITIES
# =============================================================================

def parse_dataset(dataset_path: str) -> Dict[str, Any]:
    """Parse dataset file and extract instance info."""
    with open(dataset_path) as f:
        # Handle both single-line JSON and JSONL
        content = f.read().strip()
        if content.startswith('['):
            # JSON array
            data = json.loads(content)
            return data[0] if isinstance(data, list) else data
        else:
            # Single JSON object or first line of JSONL
            first_line = content.split('\n')[0]
            return json.loads(first_line)

def is_swelancer_task(data: Dict[str, Any]) -> bool:
    """Check if this is a SWE-Lancer task."""
    repo = data.get('repo', '')
    parser = data.get('test_output_parser', '')
    return 'Expensify' in repo or 'swelancer' in parser or 'playwright' in parser

# =============================================================================
# EVALUATION
# =============================================================================

def run_trajectory_generation(
    model_config: str,
    dataset_path: str,
    max_iterations: int,
    num_workers: int,
    eval_note: str
) -> Tuple[bool, str]:
    """Run trajectory generation using OpenHands."""
    log("Starting trajectory generation...")
    
    cmd = f"""
cd ~/VeloraHarness && source .venv/bin/activate
poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent-cls CodeActAgent \
    --llm-config {model_config} \
    --max-iterations {max_iterations} \
    --eval-num-workers {num_workers} \
    --eval-note {eval_note} \
    --dataset {dataset_path} \
    --split train \
    --eval-n-limit 1
"""
    
    rc, stdout, stderr = run_command(cmd)
    
    if rc != 0:
        return False, stderr or stdout
    
    # Find output file
    output_base = os.path.expanduser("~/VeloraHarness/evaluation/evaluation_outputs/outputs")
    
    # Search for output.jsonl
    rc, found, _ = run_command(
        f"find {output_base} -name 'output.jsonl' -type f | head -1",
        capture=True
    )
    
    if rc == 0 and found.strip():
        return True, found.strip()
    
    return False, "Could not find output.jsonl"

def run_patch_evaluation(
    trajectory_file: str,
    dataset_path: str,
    docker_image: str,
    output_file: str,
    timeout: int = 600
) -> Tuple[bool, Dict[str, Any]]:
    """Run patch evaluation."""
    log("Starting patch evaluation...")
    
    script_path = os.path.expanduser(
        "~/VeloraHarness/evaluation/benchmarks/multi_swe_bench/scripts/eval_pilot2_standardized.py"
    )
    
    cmd = f"""
python3 {script_path} \
    --trajectory-file {trajectory_file} \
    --dataset-file {dataset_path} \
    --docker-image {docker_image} \
    --output-file {output_file} \
    --timeout {timeout}
"""
    
    rc, stdout, stderr = run_command(cmd)
    
    if rc != 0:
        return False, {"error": stderr or stdout}
    
    # Parse result
    try:
        with open(output_file) as f:
            result = json.load(f)
        return True, result
    except Exception as e:
        return False, {"error": str(e)}

# =============================================================================
# MAIN
# =============================================================================

def main():
    parser = argparse.ArgumentParser(description="Single Instance Evaluation")
    
    parser.add_argument('--model', '-m', type=str, default='gemini',
                        help='Model name: gemini, claude, gpt')
    parser.add_argument('--model-config', type=str, default=None,
                        help='LLM config name (overrides --model)')
    parser.add_argument('--dataset', '-d', type=str, required=True,
                        help='Path to dataset file (single instance)')
    parser.add_argument('--max-iterations', type=int, default=1000,
                        help='Max iterations for agent')
    parser.add_argument('--num-workers', type=int, default=1,
                        help='Number of parallel workers')
    parser.add_argument('--timeout', type=int, default=600,
                        help='Evaluation timeout in seconds')
    parser.add_argument('--run-number', type=int, default=1,
                        help='Run number for eval note')
    parser.add_argument('--fresh-container', action='store_true', default=True,
                        help='Use fresh container (default: True)')
    parser.add_argument('--output-dir', type=str, default=None,
                        help='Output directory')
    
    args = parser.parse_args()
    
    # Resolve model config
    model_config = args.model_config or MODEL_CONFIG_MAP.get(args.model, f'llm.{args.model}')
    
    log("=" * 70)
    log("VELORA SINGLE INSTANCE EVALUATION")
    log("=" * 70)
    log(f"Model Config: {model_config}")
    log(f"Dataset: {args.dataset}")
    log(f"Max Iterations: {args.max_iterations}")
    log(f"Timeout: {args.timeout}s")
    
    # Pre-run checks
    disk_gb = get_disk_space_gb()
    mem_gb = get_memory_gb()
    log(f"Available disk: {disk_gb}GB, memory: {mem_gb}GB")
    
    if disk_gb < 10:
        log("Low disk space, running cleanup...", "WARNING")
        docker_cleanup()
    
    # Parse dataset
    dataset_path = os.path.abspath(args.dataset)
    data = parse_dataset(dataset_path)
    instance_id = data.get('instance_id', 'unknown')
    base_commit = data.get('base_commit', '')
    
    log(f"Instance ID: {instance_id}")
    log(f"Base Commit: {base_commit[:12] if base_commit else 'N/A'}")
    
    # Check if SWE-Lancer task
    is_swelancer = is_swelancer_task(data)
    if is_swelancer:
        log("Detected SWE-Lancer task")
        $USE_SWELANCER_MONOLITH = "true"
        $SWELANCER_MONOLITH_IMAGE = "swelancer/unified:latest"
    
    # Determine Docker image
    if is_swelancer and os.environ.get('USE_SWELANCER_MONOLITH') == 'true':
        docker_image = os.environ.get('SWELANCER_MONOLITH_IMAGE', 'swelancer/unified:latest')
    else:
        docker_image = data.get('image_storage_uri', '')
    
    log(f"Docker Image: {docker_image}")
    
    # Check/load Docker image
    if not docker_image_exists(docker_image):
        if docker_image.startswith('s3://'):
            local_file = os.path.basename(docker_image)
            if not load_docker_from_s3(docker_image, local_file):
                log("Failed to load Docker image", "ERROR")
                sys.exit(1)
        else:
            log(f"Docker image not found: {docker_image}", "ERROR")
            sys.exit(1)
    
    # Tag image for OpenHands
    repo = data.get('repo', 'unknown').replace('/', '_m_').lower()
    tag1 = f"mswebench/sweb.eval.x86_64.{instance_id}:latest"
    tag2 = f"mswebench/{repo}:pr-{instance_id}"
    
    # Check for fixed monolith image
    fixed_tag = "mswebench/swelancer_monolith_fixed:latest"
    if is_swelancer:
        rc, _, _ = run_command(f"docker run --rm --entrypoint /bin/bash {fixed_tag} -c 'which tmux' 2>/dev/null", capture=True)
        if rc == 0:
            log(f"Using existing fixed monolith: {fixed_tag}")
            run_command(f"docker tag {fixed_tag} {tag1}")
            run_command(f"docker tag {fixed_tag} {tag2}")
        else:
            # Check if source has tmux
            rc, _, _ = run_command(f"docker run --rm --entrypoint /bin/bash {docker_image} -c 'which tmux' 2>/dev/null", capture=True)
            if rc == 0:
                run_command(f"docker tag {docker_image} {fixed_tag}")
            else:
                fix_docker_image_with_tmux(docker_image, fixed_tag)
            run_command(f"docker tag {fixed_tag} {tag1}")
            run_command(f"docker tag {fixed_tag} {tag2}")
    else:
        run_command(f"docker tag {docker_image} {tag1}")
        run_command(f"docker tag {docker_image} {tag2}")
    
    log(f"Tagged: {tag1}")
    
    # Run trajectory generation
    eval_note = f"v1.1.0-no-hint-run_{args.run_number}"
    success, output_path = run_trajectory_generation(
        model_config,
        dataset_path,
        args.max_iterations,
        args.num_workers,
        eval_note
    )
    
    if not success:
        log(f"Trajectory generation failed: {output_path}", "ERROR")
        sys.exit(1)
    
    log(f"Trajectory output: {output_path}", "SUCCESS")
    
    # Check for patch
    with open(output_path) as f:
        traj_data = json.load(f)
    
    patch = traj_data.get('test_result', {}).get('git_patch', '')
    if len(patch) < 100:
        log("No valid patch found in trajectory", "WARNING")
        sys.exit(0)
    
    # Run evaluation
    output_dir = os.path.dirname(output_path)
    eval_output_file = os.path.join(output_dir, 'eval_pilot2_output.jsonl')
    
    success, result = run_patch_evaluation(
        output_path,
        dataset_path,
        docker_image if is_swelancer else tag1,
        eval_output_file,
        args.timeout
    )
    
    if not success:
        log(f"Evaluation failed: {result.get('error', 'Unknown')}", "ERROR")
        sys.exit(1)
    
    # Extract result
    details = result.get('pilot2_eval_details', {})
    resolved = result.get('resolved', False)
    
    log("=" * 70)
    log("EVALUATION RESULT")
    log("=" * 70)
    log(f"Instance: {instance_id}")
    log(f"Resolved: {resolved}")
    log(f"Tests Passed: {details.get('tests_passed', 0)}")
    log(f"Tests Failed: {details.get('tests_failed', 0)}")
    log("=" * 70)
    
    # Create OpenHands-format report
    eval_outputs_dir = os.path.join(output_dir, 'eval_outputs', instance_id)
    os.makedirs(eval_outputs_dir, exist_ok=True)
    
    report = {
        instance_id: {
            "patch_is_None": False,
            "patch_exists": True,
            "patch_successfully_applied": not details.get('failed_apply_patch', False),
            "resolved": resolved,
            "tests_status": {
                "FAIL_TO_PASS": {
                    "success": details.get('fail_to_pass_success', []),
                    "failure": details.get('fail_to_pass_failed', [])
                },
                "PASS_TO_PASS": {
                    "success": details.get('pass_to_pass_success', []),
                    "failure": details.get('pass_to_pass_failed', [])
                }
            }
        }
    }
    
    with open(os.path.join(eval_outputs_dir, 'report.json'), 'w') as f:
        json.dump(report, f, indent=2)
    
    with open(os.path.join(eval_outputs_dir, 'test_output.txt'), 'w') as f:
        f.write(details.get('test_output', ''))
    
    with open(os.path.join(eval_outputs_dir, 'patch.diff'), 'w') as f:
        f.write(patch)
    
    log(f"Results saved to: {eval_outputs_dir}", "SUCCESS")
    
    # Cleanup
    docker_cleanup()
    
    log("Evaluation complete!", "SUCCESS")
    sys.exit(0 if resolved else 1)

if __name__ == '__main__':
    main()
