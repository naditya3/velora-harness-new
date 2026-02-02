#!/usr/bin/env xonsh
"""
EC2 Instance Setup Script

This script sets up a fresh Ubuntu EC2 instance with all dependencies
required for Velora evaluations.

Usage:
    ./ec2_setup.xsh --host aws-velora-gemini
    ./ec2_setup.xsh --host 54.123.45.67 --ssh-key ~/.ssh/my-key.pem --ssh-user ubuntu
"""

import argparse
import subprocess
import sys
import time
from typing import Tuple, Optional

# =============================================================================
# CONFIGURATION
# =============================================================================

REQUIRED_PACKAGES = [
    'python3', 'python3-pip', 'python3-venv',
    'git', 'curl', 'wget', 'unzip',
    'apt-transport-https', 'ca-certificates',
    'software-properties-common'
]

DOCKER_INSTALL_SCRIPT = """
# Install Docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER
"""

AWS_CLI_INSTALL_SCRIPT = """
# Install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
sudo ./aws/install
rm -rf aws awscliv2.zip
"""

POETRY_INSTALL_SCRIPT = """
# Install Poetry
curl -sSL https://install.python-poetry.org | python3 -
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/.local/bin:$PATH"
"""

NVM_INSTALL_SCRIPT = """
# Install NVM and Node.js
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm install 20.15.1
nvm install 20.18.0
nvm alias default 20.15.1
"""

S3_DOCKER_IMAGE = "s3://rfp-coding-q1/Images/RCT/Expensify_App-unified_x86_monolith.tar"

# =============================================================================
# SSH UTILITIES
# =============================================================================

def run_ssh(host: str, user: str, key: Optional[str], command: str, timeout: int = 600) -> Tuple[int, str, str]:
    """Run command on remote host via SSH."""
    if key:
        ssh_cmd = f"ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -i {key} {user}@{host}"
    else:
        # Assume host is in SSH config
        ssh_cmd = f"ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no {host}"
    
    full_cmd = f"{ssh_cmd} '{command}'"
    try:
        result = subprocess.run(full_cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "Command timed out"
    except Exception as e:
        return -1, "", str(e)

def run_scp(host: str, user: str, key: Optional[str], local: str, remote: str, to_remote: bool = True) -> bool:
    """Copy files via SCP."""
    if key:
        scp_base = f"scp -o StrictHostKeyChecking=no -i {key}"
        remote_spec = f"{user}@{host}:{remote}"
    else:
        scp_base = f"scp -o StrictHostKeyChecking=no"
        remote_spec = f"{host}:{remote}"
    
    if to_remote:
        scp_cmd = f"{scp_base} -r {local} {remote_spec}"
    else:
        scp_cmd = f"{scp_base} -r {remote_spec} {local}"
    
    try:
        result = subprocess.run(scp_cmd, shell=True, capture_output=True, text=True, timeout=600)
        return result.returncode == 0
    except Exception:
        return False

# =============================================================================
# SETUP FUNCTIONS
# =============================================================================

def check_connection(host: str, user: str, key: Optional[str]) -> bool:
    """Check SSH connection."""
    print(f"Checking connection to {host}...")
    rc, stdout, stderr = run_ssh(host, user, key, "echo 'Connection OK'", timeout=30)
    if rc == 0 and 'Connection OK' in stdout:
        print(f"  ✓ Connection successful")
        return True
    print(f"  ✗ Connection failed: {stderr}")
    return False

def check_prerequisites(host: str, user: str, key: Optional[str]) -> dict:
    """Check what's installed on the instance."""
    print(f"Checking prerequisites on {host}...")
    
    checks = {
        'python': 'python3 --version 2>/dev/null',
        'pip': 'pip3 --version 2>/dev/null',
        'docker': 'docker --version 2>/dev/null',
        'git': 'git --version 2>/dev/null',
        'aws_cli': 'aws --version 2>/dev/null',
        'poetry': 'poetry --version 2>/dev/null',
        'nvm': 'source ~/.nvm/nvm.sh 2>/dev/null && nvm --version',
        'node': 'source ~/.nvm/nvm.sh 2>/dev/null && node --version',
        'velora_harness': 'test -d ~/VeloraHarness && echo "exists"',
        'docker_image': 'docker images -q swelancer/unified:latest 2>/dev/null',
        'docker_running': 'docker ps 2>/dev/null | grep -q "" && echo "running"',
    }
    
    results = {}
    for name, cmd in checks.items():
        rc, stdout, _ = run_ssh(host, user, key, cmd, timeout=30)
        results[name] = rc == 0 and bool(stdout.strip())
        status = "✓" if results[name] else "✗"
        print(f"  {status} {name}")
    
    return results

def install_base_packages(host: str, user: str, key: Optional[str]) -> bool:
    """Install base Ubuntu packages."""
    print(f"Installing base packages on {host}...")
    
    cmd = f"""
sudo apt-get update
sudo apt-get install -y {' '.join(REQUIRED_PACKAGES)}
"""
    
    rc, stdout, stderr = run_ssh(host, user, key, cmd, timeout=300)
    if rc != 0:
        print(f"  ✗ Failed: {stderr[:200]}")
        return False
    print("  ✓ Base packages installed")
    return True

def install_docker(host: str, user: str, key: Optional[str]) -> bool:
    """Install Docker."""
    print(f"Installing Docker on {host}...")
    
    rc, stdout, stderr = run_ssh(host, user, key, DOCKER_INSTALL_SCRIPT, timeout=300)
    if rc != 0:
        print(f"  ✗ Failed: {stderr[:200]}")
        return False
    print("  ✓ Docker installed")
    return True

def install_aws_cli(host: str, user: str, key: Optional[str]) -> bool:
    """Install AWS CLI."""
    print(f"Installing AWS CLI on {host}...")
    
    rc, stdout, stderr = run_ssh(host, user, key, AWS_CLI_INSTALL_SCRIPT, timeout=300)
    if rc != 0:
        print(f"  ✗ Failed: {stderr[:200]}")
        return False
    print("  ✓ AWS CLI installed")
    return True

def install_poetry(host: str, user: str, key: Optional[str]) -> bool:
    """Install Poetry."""
    print(f"Installing Poetry on {host}...")
    
    rc, stdout, stderr = run_ssh(host, user, key, POETRY_INSTALL_SCRIPT, timeout=300)
    if rc != 0:
        print(f"  ✗ Failed: {stderr[:200]}")
        return False
    print("  ✓ Poetry installed")
    return True

def install_nvm_node(host: str, user: str, key: Optional[str]) -> bool:
    """Install NVM and Node.js."""
    print(f"Installing NVM and Node.js on {host}...")
    
    rc, stdout, stderr = run_ssh(host, user, key, NVM_INSTALL_SCRIPT, timeout=300)
    if rc != 0:
        print(f"  ✗ Failed: {stderr[:200]}")
        return False
    print("  ✓ NVM and Node.js installed")
    return True

def sync_velora_harness(host: str, user: str, key: Optional[str], local_path: str) -> bool:
    """Sync VeloraHarness to remote host."""
    print(f"Syncing VeloraHarness to {host}...")
    
    # Use rsync if available, otherwise scp
    if key:
        rsync_cmd = f"rsync -avz --exclude '.venv' --exclude '__pycache__' --exclude '*.pyc' -e 'ssh -i {key}' {local_path}/ {user}@{host}:~/VeloraHarness/"
    else:
        rsync_cmd = f"rsync -avz --exclude '.venv' --exclude '__pycache__' --exclude '*.pyc' {local_path}/ {host}:~/VeloraHarness/"
    
    try:
        result = subprocess.run(rsync_cmd, shell=True, capture_output=True, text=True, timeout=600)
        if result.returncode == 0:
            print("  ✓ VeloraHarness synced")
            return True
    except:
        pass
    
    # Fallback to scp
    print("  rsync failed, trying scp...")
    if run_scp(host, user, key, local_path, "~/VeloraHarness", to_remote=True):
        print("  ✓ VeloraHarness synced (via scp)")
        return True
    
    print("  ✗ Failed to sync VeloraHarness")
    return False

def copy_config(host: str, user: str, key: Optional[str], config_path: str) -> bool:
    """Copy config.toml to remote host."""
    print(f"Copying config.toml to {host}...")
    
    if run_scp(host, user, key, config_path, "~/VeloraHarness/config.toml", to_remote=True):
        print("  ✓ config.toml copied")
        return True
    
    print("  ✗ Failed to copy config.toml")
    return False

def copy_aws_credentials(host: str, user: str, key: Optional[str]) -> bool:
    """Copy AWS credentials to remote host."""
    print(f"Copying AWS credentials to {host}...")
    
    # Create .aws directory
    run_ssh(host, user, key, "mkdir -p ~/.aws", timeout=30)
    
    # Copy credentials and config
    success = True
    for file in ['credentials', 'config']:
        local_path = f"~/.aws/{file}"
        if run_scp(host, user, key, local_path, f"~/.aws/{file}", to_remote=True):
            print(f"  ✓ {file} copied")
        else:
            print(f"  ✗ Failed to copy {file}")
            success = False
    
    return success

def install_python_deps(host: str, user: str, key: Optional[str]) -> bool:
    """Install Python dependencies via Poetry."""
    print(f"Installing Python dependencies on {host}...")
    
    cmd = """
cd ~/VeloraHarness
export PATH="$HOME/.local/bin:$PATH"
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
poetry install 2>&1 | tail -10
"""
    
    rc, stdout, stderr = run_ssh(host, user, key, cmd, timeout=600)
    if rc != 0:
        print(f"  ✗ Failed: {stderr[:200]}")
        return False
    print("  ✓ Python dependencies installed")
    return True

def load_docker_image(host: str, user: str, key: Optional[str]) -> bool:
    """Load Docker image from S3."""
    print(f"Loading Docker image on {host} from S3...")
    
    cmd = f"""
aws s3 cp {S3_DOCKER_IMAGE} /tmp/docker_image.tar --only-show-errors
docker load < /tmp/docker_image.tar
docker tag swelancer/unified:v12 swelancer/unified:latest 2>/dev/null || true
rm -f /tmp/docker_image.tar
docker images | grep swelancer
"""
    
    rc, stdout, stderr = run_ssh(host, user, key, cmd, timeout=1800)
    if rc != 0:
        print(f"  ✗ Failed: {stderr[:200]}")
        return False
    print("  ✓ Docker image loaded")
    print(f"    {stdout.strip()}")
    return True

# =============================================================================
# MAIN
# =============================================================================

def main():
    parser = argparse.ArgumentParser(description="EC2 Instance Setup")
    
    parser.add_argument('--host', '-H', type=str, required=True,
                        help='Hostname or IP address')
    parser.add_argument('--ssh-key', '-k', type=str, default=None,
                        help='Path to SSH private key')
    parser.add_argument('--ssh-user', '-u', type=str, default='ubuntu',
                        help='SSH username (default: ubuntu)')
    parser.add_argument('--velora-path', type=str, default='.',
                        help='Local path to VeloraHarness')
    parser.add_argument('--config-toml', type=str, default='./config.toml',
                        help='Path to config.toml')
    parser.add_argument('--skip-docker-image', action='store_true',
                        help='Skip Docker image loading')
    parser.add_argument('--force', action='store_true',
                        help='Force reinstall even if already installed')
    
    args = parser.parse_args()
    
    print("=" * 70)
    print("EC2 INSTANCE SETUP")
    print("=" * 70)
    print(f"Host: {args.host}")
    print(f"User: {args.ssh_user}")
    print(f"SSH Key: {args.ssh_key or '(from SSH config)'}")
    print("")
    
    # Check connection
    if not check_connection(args.host, args.ssh_user, args.ssh_key):
        print("\nFailed to connect to host. Check SSH configuration.")
        sys.exit(1)
    
    # Check prerequisites
    prereqs = check_prerequisites(args.host, args.ssh_user, args.ssh_key)
    
    # Install missing components
    if not prereqs['python'] or not prereqs['pip'] or args.force:
        if not install_base_packages(args.host, args.ssh_user, args.ssh_key):
            sys.exit(1)
    
    if not prereqs['docker'] or args.force:
        if not install_docker(args.host, args.ssh_user, args.ssh_key):
            sys.exit(1)
    
    if not prereqs['aws_cli'] or args.force:
        if not install_aws_cli(args.host, args.ssh_user, args.ssh_key):
            sys.exit(1)
    
    if not prereqs['poetry'] or args.force:
        if not install_poetry(args.host, args.ssh_user, args.ssh_key):
            sys.exit(1)
    
    if not prereqs['nvm'] or not prereqs['node'] or args.force:
        if not install_nvm_node(args.host, args.ssh_user, args.ssh_key):
            sys.exit(1)
    
    # Sync VeloraHarness
    import os
    velora_path = os.path.abspath(os.path.expanduser(args.velora_path))
    if not prereqs['velora_harness'] or args.force:
        if not sync_velora_harness(args.host, args.ssh_user, args.ssh_key, velora_path):
            sys.exit(1)
    
    # Copy config
    config_path = os.path.abspath(os.path.expanduser(args.config_toml))
    if not copy_config(args.host, args.ssh_user, args.ssh_key, config_path):
        sys.exit(1)
    
    # Copy AWS credentials
    copy_aws_credentials(args.host, args.ssh_user, args.ssh_key)
    
    # Install Python dependencies
    if not prereqs['velora_harness'] or args.force:
        if not install_python_deps(args.host, args.ssh_user, args.ssh_key):
            sys.exit(1)
    
    # Load Docker image
    if not args.skip_docker_image and (not prereqs['docker_image'] or args.force):
        if not load_docker_image(args.host, args.ssh_user, args.ssh_key):
            print("  Warning: Docker image load failed, continuing anyway...")
    
    print("")
    print("=" * 70)
    print("SETUP COMPLETE")
    print("=" * 70)
    print(f"Host {args.host} is ready for evaluations.")
    print("")
    print("Next steps:")
    print(f"  1. SSH to host: ssh {args.host}")
    print("  2. Run evaluation: cd ~/VeloraHarness && ./evaluation/scripts/velora_eval_runner.xsh")
    print("")

if __name__ == '__main__':
    main()
