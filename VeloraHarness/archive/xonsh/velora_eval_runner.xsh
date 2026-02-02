#!/usr/bin/env xonsh
"""
Velora Evaluation Runner - Complete Pass@k Evaluation System

This script orchestrates pass@k evaluations across multiple models and optionally
multiple EC2 instances. It's designed to run unattended overnight.

Features:
- Multi-model evaluation (gemini, claude, gpt)
- Pass@k evaluation with configurable k
- Multi-EC2 distributed execution
- Automatic EC2 setup for fresh instances
- Comprehensive logging and progress tracking
- Resume capability via checkpoints
- Result aggregation and summary generation

Usage Examples:
    # Single host, single model, all instances
    ./velora_eval_runner.xsh --models gemini --runs 8
    
    # Multiple models, specific instances
    ./velora_eval_runner.xsh --models gemini,claude,gpt --runs 8 --instances 1769880766122899,1769880766142606
    
    # Distributed across multiple EC2 instances
    ./velora_eval_runner.xsh --models gemini --runs 8 --hosts aws-velora-1,aws-velora-2 --parallel
    
    # Using IP addresses with SSH key
    ./velora_eval_runner.xsh --models gemini --runs 8 --hosts 54.123.45.67,54.123.45.68 --ssh-key ~/.ssh/my-key.pem
"""

import argparse
import json
import os
import sys
import subprocess
import time
import datetime
import shutil
from pathlib import Path
from typing import List, Dict, Any, Optional, Tuple
from dataclasses import dataclass, asdict
from concurrent.futures import ThreadPoolExecutor, as_completed
import threading

# =============================================================================
# CONFIGURATION
# =============================================================================

MODEL_CONFIG_MAP = {
    'gemini': 'llm.gemini3',
    'claude': 'llm.claude',
    'gpt': 'llm.gpt'
}

DEFAULT_SETTINGS = {
    'max_iterations': 1000,
    'timeout_minutes': 45,  # Increased to handle trajectory generation + evaluation
    'retries': 3,
    'runs': 8,
    'num_workers': 1,
    'fresh_container': True,
    'distribution': 'by-data',  # 'by-model', 'by-data', 'matrix'
    'ssh_user': 'ubuntu',
    's3_docker_image': 's3://rfp-coding-q1/Images/RCT/Expensify_App-unified_x86_monolith.tar',
    'docker_image_name': 'swelancer/unified:latest',
    'output_dir': './evaluation/evaluation_outputs',  # Default output directory
}

# =============================================================================
# DATA CLASSES
# =============================================================================

@dataclass
class EvalResult:
    instance_id: str
    model: str
    run: int
    resolved: bool
    tests_passed: int
    tests_failed: int
    error: Optional[str] = None
    duration_seconds: float = 0.0
    output_dir: str = ""

@dataclass
class HostConfig:
    hostname: str
    ssh_user: str
    ssh_key: Optional[str]
    is_ssh_config: bool  # True if hostname is from ~/.ssh/config

@dataclass
class Progress:
    completed: List[Tuple[str, str, int]]  # (instance_id, model, run)
    failed: List[Tuple[str, str, int, str]]  # (instance_id, model, run, error)
    total_instances: int
    total_models: int
    total_runs: int

# =============================================================================
# LOGGING
# =============================================================================

class Logger:
    def __init__(self, log_dir: str):
        self.log_dir = Path(log_dir)
        self.log_dir.mkdir(parents=True, exist_ok=True)
        timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        self.master_log = self.log_dir / f"evaluation_master_{timestamp}.log"
        self._lock = threading.Lock()
        
    def log(self, message: str, level: str = "INFO"):
        timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        log_line = f"[{timestamp}] [{level}] {message}"
        print(log_line)
        with self._lock:
            with open(self.master_log, 'a') as f:
                f.write(log_line + "\n")
    
    def info(self, message: str):
        self.log(message, "INFO")
    
    def error(self, message: str):
        self.log(message, "ERROR")
    
    def warning(self, message: str):
        self.log(message, "WARNING")
    
    def success(self, message: str):
        self.log(message, "SUCCESS")

# =============================================================================
# COMMAND EXECUTION UTILITIES
# =============================================================================

def run_local_command(command: str, timeout: int = 300) -> Tuple[int, str, str]:
    """Run command locally."""
    try:
        result = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout,
            executable='/bin/bash'
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "Command timed out"
    except Exception as e:
        return -1, "", str(e)

def run_ssh_command(host: HostConfig, command: str, timeout: int = 300) -> Tuple[int, str, str]:
    """Run command on remote host via SSH."""
    if host.is_ssh_config:
        ssh_cmd = f"ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no {host.hostname}"
    else:
        key_arg = f"-i {host.ssh_key}" if host.ssh_key else ""
        ssh_cmd = f"ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no {key_arg} {host.ssh_user}@{host.hostname}"
    
    full_cmd = f"{ssh_cmd} '{command}'"
    try:
        result = subprocess.run(
            full_cmd,
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "Command timed out"
    except Exception as e:
        return -1, "", str(e)

def run_command_on_host(host: HostConfig, command: str, timeout: int = 300) -> Tuple[int, str, str]:
    """Run command on host - locally if localhost, otherwise via SSH."""
    if host.hostname == 'localhost':
        return run_local_command(command, timeout)
    else:
        return run_ssh_command(host, command, timeout)

def run_scp(host: HostConfig, local_path: str, remote_path: str, to_remote: bool = True) -> bool:
    """Copy files via SCP."""
    if host.is_ssh_config:
        if to_remote:
            scp_cmd = f"scp -o StrictHostKeyChecking=no -r {local_path} {host.hostname}:{remote_path}"
        else:
            scp_cmd = f"scp -o StrictHostKeyChecking=no -r {host.hostname}:{remote_path} {local_path}"
    else:
        key_arg = f"-i {host.ssh_key}" if host.ssh_key else ""
        if to_remote:
            scp_cmd = f"scp -o StrictHostKeyChecking=no {key_arg} -r {local_path} {host.ssh_user}@{host.hostname}:{remote_path}"
        else:
            scp_cmd = f"scp -o StrictHostKeyChecking=no {key_arg} -r {host.ssh_user}@{host.hostname}:{remote_path} {local_path}"
    
    try:
        result = subprocess.run(scp_cmd, shell=True, capture_output=True, text=True, timeout=600)
        return result.returncode == 0
    except Exception:
        return False

# =============================================================================
# EC2 SETUP
# =============================================================================

def check_ec2_prerequisites(host: HostConfig, logger: Logger) -> Dict[str, bool]:
    """Check what's installed on EC2 instance."""
    checks = {
        'python': 'python3 --version',
        'docker': 'docker --version',
        'git': 'git --version',
        'aws_cli': 'aws --version',
        'poetry': 'poetry --version',
        'nvm': 'source ~/.nvm/nvm.sh && nvm --version',
        'velora_harness': 'test -d ~/VeloraHarness && echo "exists"',
        'docker_image': f'docker images -q swelancer/unified:latest',
    }
    
    results = {}
    for name, cmd in checks.items():
        returncode, stdout, stderr = run_ssh_command(host, cmd, timeout=30)
        results[name] = returncode == 0 and bool(stdout.strip())
        status = "✓" if results[name] else "✗"
        logger.info(f"  {host.hostname}: {name} {status}")
    
    return results

def setup_ec2_instance(host: HostConfig, logger: Logger, config_toml_path: str) -> bool:
    """Set up a fresh EC2 instance with all dependencies."""
    logger.info(f"Setting up EC2 instance: {host.hostname}")
    
    # Check prerequisites
    prereqs = check_ec2_prerequisites(host, logger)
    
    setup_commands = []
    
    # Python
    if not prereqs.get('python'):
        setup_commands.append("""
sudo apt-get update && sudo apt-get install -y python3 python3-pip python3-venv
""")
    
    # Git
    if not prereqs.get('git'):
        setup_commands.append("sudo apt-get install -y git")
    
    # Docker
    if not prereqs.get('docker'):
        setup_commands.append("""
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io
sudo usermod -aG docker $USER
""")
    
    # AWS CLI
    if not prereqs.get('aws_cli'):
        setup_commands.append("""
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip && sudo ./aws/install && rm -rf aws awscliv2.zip
""")
    
    # Poetry
    if not prereqs.get('poetry'):
        setup_commands.append("""
curl -sSL https://install.python-poetry.org | python3 -
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
""")
    
    # NVM and Node
    if not prereqs.get('nvm'):
        setup_commands.append("""
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
source ~/.nvm/nvm.sh && nvm install 20.15.1 && nvm install 20.18.0
""")
    
    # Run setup commands
    for cmd in setup_commands:
        logger.info(f"  Running setup on {host.hostname}...")
        returncode, stdout, stderr = run_ssh_command(host, cmd, timeout=600)
        if returncode != 0:
            logger.error(f"  Setup failed: {stderr}")
            return False
    
    # Clone VeloraHarness if not present
    if not prereqs.get('velora_harness'):
        logger.info(f"  Syncing VeloraHarness to {host.hostname}...")
        # Use rsync or scp to sync the local VeloraHarness
        velora_path = Path(__file__).parent.parent.parent.parent
        if not run_scp(host, str(velora_path), "~/", to_remote=True):
            logger.error("  Failed to sync VeloraHarness")
            return False
    
    # Copy config.toml
    logger.info(f"  Copying config.toml to {host.hostname}...")
    if not run_scp(host, config_toml_path, "~/VeloraHarness/config.toml", to_remote=True):
        logger.error("  Failed to copy config.toml")
        return False
    
    # Install Python dependencies
    logger.info(f"  Installing Python dependencies on {host.hostname}...")
    returncode, stdout, stderr = run_ssh_command(
        host,
        "cd ~/VeloraHarness && poetry install 2>&1 | tail -5",
        timeout=600
    )
    
    # Load Docker image if not present
    if not prereqs.get('docker_image'):
        logger.info(f"  Loading Docker image on {host.hostname} from S3...")
        s3_path = DEFAULT_SETTINGS['s3_docker_image']
        load_cmd = f"""
aws s3 cp {s3_path} /tmp/docker_image.tar --only-show-errors &&
docker load < /tmp/docker_image.tar &&
rm -f /tmp/docker_image.tar
"""
        returncode, stdout, stderr = run_ssh_command(host, load_cmd, timeout=1800)
        if returncode != 0:
            logger.warning(f"  Docker image load may have failed: {stderr}")
    
    logger.success(f"  EC2 instance {host.hostname} setup complete")
    return True

# =============================================================================
# DATASET UTILITIES
# =============================================================================

def get_dataset_instances(dataset_dir: str, instances_filter: Optional[str] = None) -> List[str]:
    """Get list of instance IDs from dataset directory."""
    dataset_path = Path(dataset_dir)
    
    # Check for instances subdirectory
    instances_path = dataset_path / "instances"
    if instances_path.exists():
        dataset_path = instances_path
    
    # Get all jsonl files
    jsonl_files = sorted(dataset_path.glob("*.jsonl"))
    
    instance_ids = []
    for f in jsonl_files:
        # Extract instance_id from filename or file content
        if f.stem.isdigit() or f.stem.startswith("17"):  # Instance ID pattern
            instance_ids.append(f.stem)
        else:
            # Read from file
            try:
                with open(f) as fp:
                    data = json.loads(fp.readline())
                    if 'instance_id' in data:
                        instance_ids.append(str(data['instance_id']))
            except:
                pass
    
    # Apply filter
    if instances_filter:
        if instances_filter == 'all':
            pass  # No filter
        elif ':' in instances_filter:
            # Range like "0:10" or "5:15"
            start, end = map(int, instances_filter.split(':'))
            instance_ids = instance_ids[start:end]
        elif ',' in instances_filter:
            # Specific instances
            filter_set = set(instances_filter.split(','))
            instance_ids = [i for i in instance_ids if i in filter_set]
        else:
            # Single instance
            instance_ids = [i for i in instance_ids if i == instances_filter]
    
    return instance_ids

def distribute_work(
    instances: List[str],
    models: List[str],
    runs: int,
    hosts: List[HostConfig],
    distribution: str
) -> Dict[str, List[Tuple[str, str, int]]]:
    """Distribute work across hosts."""
    work_per_host = {h.hostname: [] for h in hosts}
    
    if distribution == 'by-model':
        # Each host gets different models
        for i, model in enumerate(models):
            host = hosts[i % len(hosts)]
            for instance_id in instances:
                for run in range(1, runs + 1):
                    work_per_host[host.hostname].append((instance_id, model, run))
    
    elif distribution == 'by-data':
        # Split instances across hosts, all run same models
        instances_per_host = len(instances) // len(hosts)
        remainder = len(instances) % len(hosts)
        
        idx = 0
        for i, host in enumerate(hosts):
            count = instances_per_host + (1 if i < remainder else 0)
            host_instances = instances[idx:idx + count]
            idx += count
            
            for model in models:
                for instance_id in host_instances:
                    for run in range(1, runs + 1):
                        work_per_host[host.hostname].append((instance_id, model, run))
    
    elif distribution == 'matrix':
        # Full matrix split evenly
        all_work = []
        for model in models:
            for instance_id in instances:
                for run in range(1, runs + 1):
                    all_work.append((instance_id, model, run))
        
        for i, work_item in enumerate(all_work):
            host = hosts[i % len(hosts)]
            work_per_host[host.hostname].append(work_item)
    
    return work_per_host

# =============================================================================
# EVALUATION EXECUTION
# =============================================================================

def run_single_evaluation(
    host: HostConfig,
    instance_id: str,
    model: str,
    run_num: int,
    settings: Dict[str, Any],
    logger: Logger,
    dataset_dir: str
) -> EvalResult:
    """Run a single evaluation on a host."""
    start_time = time.time()
    model_config = MODEL_CONFIG_MAP.get(model, model)
    
    logger.info(f"[{host.hostname}] Starting {model} run {run_num} for {instance_id}")
    
    # Build evaluation command - use absolute paths for local, ~ for remote
    if host.hostname == 'localhost':
        # Local execution - use absolute paths
        velora_home = str(Path.home() / "VeloraHarness")
        dataset_file = str(Path(dataset_dir).expanduser() / "instances" / f"{instance_id}.jsonl")
        if not Path(dataset_file).exists():
            dataset_file = str(Path(dataset_dir).expanduser() / f"{instance_id}.jsonl")
        
        eval_cmd = f"""
cd {velora_home} && source .venv/bin/activate
export USE_SWELANCER_MONOLITH=true
export SWELANCER_MONOLITH_IMAGE="swelancer/unified:latest"
export N_RUNS=1
export RUN_NUMBER_OFFSET={run_num - 1}

bash ./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh \\
    {model_config} \\
    {dataset_file} \\
    1 \\
    {settings['max_iterations']} \\
    {settings['num_workers']}
"""
    else:
        # Remote execution - use ~ paths
        dataset_file = f"~/VeloraHarness/dataset/instances/{instance_id}.jsonl"
        
        eval_cmd = f"""
cd ~/VeloraHarness && source .venv/bin/activate
export USE_SWELANCER_MONOLITH=true
export SWELANCER_MONOLITH_IMAGE="swelancer/unified:latest"
export N_RUNS=1
export RUN_NUMBER_OFFSET={run_num - 1}

bash ./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh \\
    {model_config} \\
    {dataset_file} \\
    1 \\
    {settings['max_iterations']} \\
    {settings['num_workers']}
"""
    
    # Run with retries
    last_error = None
    timeout_seconds = settings['timeout_minutes'] * 60
    
    for attempt in range(1, settings['retries'] + 1):
        logger.info(f"  [{host.hostname}] Attempt {attempt}/{settings['retries']}")
        
        returncode, stdout, stderr = run_command_on_host(
            host, eval_cmd, timeout=timeout_seconds
        )
        
        if returncode == 0:
            # Parse result
            duration = time.time() - start_time
            
            # Try to extract result from stdout
            resolved = "RESOLVED: YES" in stdout or "resolved\": true" in stdout.lower()
            tests_passed = 1 if resolved else 0
            tests_failed = 0 if resolved else 1
            
            return EvalResult(
                instance_id=instance_id,
                model=model,
                run=run_num,
                resolved=resolved,
                tests_passed=tests_passed,
                tests_failed=tests_failed,
                duration_seconds=duration
            )
        else:
            last_error = stderr or stdout or "Unknown error"
            logger.warning(f"  [{host.hostname}] Attempt {attempt} failed: {last_error[:200]}")
            time.sleep(5)  # Brief pause before retry
    
    # All retries exhausted
    duration = time.time() - start_time
    logger.error(f"  [{host.hostname}] All retries exhausted for {instance_id}")
    
    return EvalResult(
        instance_id=instance_id,
        model=model,
        run=run_num,
        resolved=False,
        tests_passed=0,
        tests_failed=1,
        error=last_error,
        duration_seconds=duration
    )

def run_evaluations_on_host(
    host: HostConfig,
    work_items: List[Tuple[str, str, int]],
    settings: Dict[str, Any],
    logger: Logger,
    progress_callback,
    dataset_dir: str
) -> List[EvalResult]:
    """Run all assigned evaluations on a single host."""
    results = []
    
    for instance_id, model, run_num in work_items:
        result = run_single_evaluation(host, instance_id, model, run_num, settings, logger, dataset_dir)
        results.append(result)
        progress_callback(result)
    
    return results

# =============================================================================
# RESULT AGGREGATION
# =============================================================================

def calculate_pass_at_k(results: List[EvalResult], k: int) -> Dict[str, float]:
    """Calculate pass@k metrics per model."""
    from collections import defaultdict
    import math
    
    # Group by (model, instance_id)
    grouped = defaultdict(list)
    for r in results:
        grouped[(r.model, r.instance_id)].append(r.resolved)
    
    # Calculate pass@k per model
    model_metrics = defaultdict(lambda: {'total': 0, 'passed': 0})
    
    for (model, instance_id), outcomes in grouped.items():
        n = len(outcomes)
        c = sum(outcomes)  # Number of successful runs
        
        # pass@k = 1 - C(n-c, k) / C(n, k)
        if n >= k:
            if c >= k:
                pass_k = 1.0
            elif n - c < k:
                pass_k = 1.0
            else:
                # Calculate using combinations
                pass_k = 1.0 - (math.comb(n - c, k) / math.comb(n, k))
        else:
            # Not enough runs
            pass_k = c / n if n > 0 else 0.0
        
        model_metrics[model]['total'] += 1
        model_metrics[model]['passed'] += pass_k
    
    # Calculate average pass@k per model
    result = {}
    for model, metrics in model_metrics.items():
        result[model] = metrics['passed'] / metrics['total'] if metrics['total'] > 0 else 0.0
    
    return result

def generate_summary(results: List[EvalResult], settings: Dict[str, Any], output_dir: str, logger: Logger):
    """Generate detailed summary report."""
    summary = {
        'timestamp': datetime.datetime.now().isoformat(),
        'settings': settings,
        'total_evaluations': len(results),
        'successful_evaluations': sum(1 for r in results if r.resolved),
        'failed_evaluations': sum(1 for r in results if not r.resolved),
        'errors': sum(1 for r in results if r.error),
        'results_by_model': {},
        'results_by_instance': {},
        'pass_at_k': {}
    }
    
    # Group by model
    from collections import defaultdict
    by_model = defaultdict(list)
    by_instance = defaultdict(list)
    
    for r in results:
        by_model[r.model].append(r)
        by_instance[r.instance_id].append(r)
    
    for model, model_results in by_model.items():
        summary['results_by_model'][model] = {
            'total': len(model_results),
            'resolved': sum(1 for r in model_results if r.resolved),
            'failed': sum(1 for r in model_results if not r.resolved),
            'avg_duration_seconds': sum(r.duration_seconds for r in model_results) / len(model_results)
        }
    
    for instance_id, instance_results in by_instance.items():
        summary['results_by_instance'][instance_id] = {
            'total': len(instance_results),
            'resolved': sum(1 for r in instance_results if r.resolved),
            'models': list(set(r.model for r in instance_results))
        }
    
    # Calculate pass@k
    k = settings.get('runs', 8)
    summary['pass_at_k'] = calculate_pass_at_k(results, k)
    
    # Save summary
    summary_path = Path(output_dir) / "evaluation_summary.json"
    with open(summary_path, 'w') as f:
        json.dump(summary, f, indent=2)
    
    # Print summary
    logger.info("=" * 70)
    logger.info("EVALUATION SUMMARY")
    logger.info("=" * 70)
    logger.info(f"Total Evaluations: {summary['total_evaluations']}")
    logger.info(f"Successful: {summary['successful_evaluations']}")
    logger.info(f"Failed: {summary['failed_evaluations']}")
    logger.info(f"Errors: {summary['errors']}")
    logger.info("")
    logger.info(f"Pass@{k} Results:")
    for model, score in summary['pass_at_k'].items():
        logger.info(f"  {model}: {score:.2%}")
    logger.info("=" * 70)
    
    return summary

# =============================================================================
# RESULT DOWNLOAD
# =============================================================================

def download_results(hosts: List[HostConfig], output_dir: str, logger: Logger):
    """Download results from all hosts as tar files."""
    local_results_dir = Path(output_dir) / "host_results"
    local_results_dir.mkdir(parents=True, exist_ok=True)
    
    for host in hosts:
        logger.info(f"Downloading results from {host.hostname}...")
        
        # Create tar on remote
        tar_name = f"results_{host.hostname}_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}.tar.gz"
        remote_tar = f"/tmp/{tar_name}"
        
        tar_cmd = f"""
cd ~/VeloraHarness/evaluation/evaluation_outputs &&
tar -czf {remote_tar} outputs/ 2>/dev/null || echo "No outputs to tar"
"""
        run_ssh_command(host, tar_cmd, timeout=300)
        
        # Download tar
        local_tar = local_results_dir / tar_name
        if run_scp(host, str(local_tar), remote_tar, to_remote=False):
            logger.success(f"  Downloaded: {local_tar}")
        else:
            logger.warning(f"  Failed to download results from {host.hostname}")

# =============================================================================
# MAIN
# =============================================================================

def parse_args():
    parser = argparse.ArgumentParser(
        description="Velora Pass@k Evaluation Runner",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    
    # Model configuration
    parser.add_argument('--models', '-m', type=str, default='gemini',
                        help='Comma-separated list of models: gemini,claude,gpt')
    parser.add_argument('--runs', '-k', type=int, default=DEFAULT_SETTINGS['runs'],
                        help=f'Number of runs per model per instance (pass@k). Default: {DEFAULT_SETTINGS["runs"]}')
    
    # Evaluation settings
    parser.add_argument('--max-iterations', type=int, default=DEFAULT_SETTINGS['max_iterations'],
                        help=f'Max iterations for agent. Default: {DEFAULT_SETTINGS["max_iterations"]}')
    parser.add_argument('--timeout', type=int, default=DEFAULT_SETTINGS['timeout_minutes'],
                        help=f'Timeout in minutes per retry attempt. Default: {DEFAULT_SETTINGS["timeout_minutes"]}')
    parser.add_argument('--retries', type=int, default=DEFAULT_SETTINGS['retries'],
                        help=f'Number of retry attempts. Default: {DEFAULT_SETTINGS["retries"]}')
    parser.add_argument('--num-workers', type=int, default=DEFAULT_SETTINGS['num_workers'],
                        help=f'Number of parallel workers per host. Default: {DEFAULT_SETTINGS["num_workers"]}')
    
    # Dataset selection
    parser.add_argument('--instances', '-i', type=str, default='all',
                        help='Instance selection: all, specific ID, comma-separated IDs, or range (0:10)')
    parser.add_argument('--dataset-dir', type=str, default='~/VeloraHarness/dataset',
                        help='Path to dataset directory')
    
    # Host configuration
    parser.add_argument('--hosts', type=str, default=None,
                        help='Comma-separated hostnames or IPs for distributed execution')
    parser.add_argument('--ssh-key', type=str, default=None,
                        help='Path to SSH private key (for IP-based hosts)')
    parser.add_argument('--ssh-user', type=str, default=DEFAULT_SETTINGS['ssh_user'],
                        help=f'SSH username. Default: {DEFAULT_SETTINGS["ssh_user"]}')
    
    # Parallelism
    parser.add_argument('--parallel', action='store_true',
                        help='Enable parallel execution across hosts')
    parser.add_argument('--distribution', type=str, default=DEFAULT_SETTINGS['distribution'],
                        choices=['by-model', 'by-data', 'matrix'],
                        help=f'Work distribution strategy. Default: {DEFAULT_SETTINGS["distribution"]}')
    
    # Container settings
    parser.add_argument('--reuse-container', action='store_true',
                        help='Reuse container between runs (default: fresh container per run)')
    
    # Output
    parser.add_argument('--output-dir', '-o', type=str, default='./evaluation/evaluation_outputs',
                        help='Output directory for results (default: ./evaluation/evaluation_outputs)')
    parser.add_argument('--config-toml', type=str, default='./config.toml',
                        help='Path to config.toml with API keys')
    
    # Resume
    parser.add_argument('--resume', action='store_true',
                        help='Resume from previous checkpoint')
    
    return parser.parse_args()

def main():
    args = parse_args()
    
    # Setup output directory and logger
    output_dir = Path(args.output_dir).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    logger = Logger(str(output_dir))
    
    logger.info("=" * 70)
    logger.info("VELORA PASS@K EVALUATION RUNNER")
    logger.info("=" * 70)
    
    # Parse models
    models = [m.strip() for m in args.models.split(',')]
    logger.info(f"Models: {models}")
    logger.info(f"Runs per model (k): {args.runs}")
    logger.info(f"Max iterations: {args.max_iterations}")
    logger.info(f"Timeout per attempt: {args.timeout} minutes")
    logger.info(f"Retries: {args.retries}")
    
    # Build settings
    settings = {
        'max_iterations': args.max_iterations,
        'timeout_minutes': args.timeout,
        'retries': args.retries,
        'runs': args.runs,
        'num_workers': args.num_workers,
        'fresh_container': not args.reuse_container,
        'distribution': args.distribution,
    }
    
    # Parse hosts
    if args.hosts:
        host_list = [h.strip() for h in args.hosts.split(',')]
        hosts = []
        for h in host_list:
            # Check if it's an IP address or hostname from ssh config
            is_ip = h.replace('.', '').isdigit()
            hosts.append(HostConfig(
                hostname=h,
                ssh_user=args.ssh_user,
                ssh_key=args.ssh_key,
                is_ssh_config=not is_ip
            ))
        logger.info(f"Hosts: {[h.hostname for h in hosts]}")
    else:
        # Local execution (or single host via ssh config)
        hosts = [HostConfig(
            hostname='localhost',
            ssh_user=args.ssh_user,
            ssh_key=None,
            is_ssh_config=True
        )]
        logger.info("Running on local host")
    
    # Setup EC2 instances if needed
    if hosts[0].hostname != 'localhost':
        logger.info("")
        logger.info("Checking/Setting up EC2 instances...")
        config_toml = Path(args.config_toml).expanduser().resolve()
        for host in hosts:
            if not setup_ec2_instance(host, logger, str(config_toml)):
                logger.error(f"Failed to setup {host.hostname}")
                sys.exit(1)
    
    # Get dataset instances
    dataset_dir = Path(args.dataset_dir).expanduser()
    instances = get_dataset_instances(str(dataset_dir), args.instances)
    logger.info(f"Dataset instances: {len(instances)}")
    
    if not instances:
        logger.error("No instances found in dataset!")
        sys.exit(1)
    
    # Distribute work
    if args.parallel and len(hosts) > 1:
        work_distribution = distribute_work(instances, models, args.runs, hosts, args.distribution)
        for hostname, work in work_distribution.items():
            logger.info(f"  {hostname}: {len(work)} tasks")
    else:
        # Sequential on first host (or local)
        work_distribution = {hosts[0].hostname: []}
        for model in models:
            for instance_id in instances:
                for run in range(1, args.runs + 1):
                    work_distribution[hosts[0].hostname].append((instance_id, model, run))
        logger.info(f"Total tasks: {len(work_distribution[hosts[0].hostname])}")
    
    # Run evaluations
    all_results = []
    results_lock = threading.Lock()
    
    def progress_callback(result: EvalResult):
        with results_lock:
            all_results.append(result)
            status = "✓" if result.resolved else "✗"
            logger.info(f"  [{status}] {result.model} run {result.run} - {result.instance_id}")
    
    logger.info("")
    logger.info("Starting evaluations...")
    start_time = time.time()
    
    if args.parallel and len(hosts) > 1:
        # Parallel execution across hosts
        with ThreadPoolExecutor(max_workers=len(hosts)) as executor:
            futures = {}
            for host in hosts:
                work = work_distribution.get(host.hostname, [])
                if work:
                    future = executor.submit(
                        run_evaluations_on_host,
                        host, work, settings, logger, progress_callback, str(dataset_dir)
                    )
                    futures[future] = host.hostname
            
            for future in as_completed(futures):
                hostname = futures[future]
                try:
                    results = future.result()
                    logger.success(f"Host {hostname} completed {len(results)} evaluations")
                except Exception as e:
                    logger.error(f"Host {hostname} failed: {e}")
    else:
        # Sequential execution
        for host in hosts:
            work = work_distribution.get(host.hostname, [])
            if work:
                run_evaluations_on_host(host, work, settings, logger, progress_callback, str(dataset_dir))
    
    total_time = time.time() - start_time
    logger.info(f"Total evaluation time: {total_time/3600:.2f} hours")
    
    # Download results from remote hosts (for distributed execution)
    if hosts[0].hostname != 'localhost':
        logger.info("")
        logger.info("Downloading results from hosts...")
        download_results(hosts, str(output_dir), logger)
    
    # Generate summary
    logger.info("")
    generate_summary(all_results, settings, str(output_dir), logger)
    
    # Create final results tar archive for easy download
    logger.info("")
    logger.info("Creating results archive...")
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    tar_name = f"evaluation_results_{timestamp}.tar.gz"
    tar_path = output_dir / tar_name
    
    try:
        import subprocess
        # Create tar of all results
        tar_cmd = f"cd {output_dir} && tar -czf {tar_name} evaluation_master_*.log evaluation_summary.json outputs/ 2>/dev/null"
        subprocess.run(tar_cmd, shell=True, timeout=600)
        logger.success(f"Results archive created: {tar_path}")
        logger.info(f"To download: scp <host>:{tar_path} ./")
    except Exception as e:
        logger.warning(f"Failed to create results archive: {e}")
    
    logger.info("")
    logger.info(f"Results saved to: {output_dir}")
    logger.success("Evaluation complete!")

if __name__ == '__main__':
    main()
