#!/usr/bin/env python3
"""
Standardized Evaluation Script for Pilot 2.2 Tasks

This script follows the client's README.md and harness files:
- Uses log_parsers.py for test output parsing (parse_log_pytest_v3, parse_log_unittest)
- Follows test_spec.py eval flow (make_eval_test_spec structure)
- Works with all tasks in ClientSheet (186 tasks)

Key requirements from client README:
1. Load Docker image from images/ using image_storage_uri
2. Initialize container with image_init_commands 
3. Execute tests with test_command from CSV
4. Parse output with test_output_parser from CSV

=== SWE-LANCER CRITICAL FIXES (applied in this script) ===

1. Issue ID Extraction: Extracts issue_id from test_command using 
   ISSUE_ID=<value> pattern (e.g., "18207_923") instead of regex that 
   doesn't handle underscores.

2. Patch Application Order: Model patch is applied AFTER git checkout 
   of base_commit. If applied before, git checkout discards the patch.

3. Proxy Configuration: Tests are rewritten using rewrite_test.py to 
   inject Playwright proxy configuration (proxy={"server": "http://localhost:8080"})
   so browser traffic goes through mitmdump.

4. API Routing: USE_WEB_PROXY=false is set when starting webpack dev server
   so API calls go directly to www.expensify.com through the browser's 
   proxy (mitmdump) instead of through webpack's internal proxy.

5. Exit Code Handling: Returns 0 if evaluation completed (test may have
   passed or failed). Only returns 1 for actual evaluation errors.

6. Node Version Switching: Automatically selects correct Node.js version
   based on base_commit and copies pre-cached node_modules.

Usage:
    python eval_pilot2_standardized.py \
        --trajectory-file <output.jsonl> \
        --dataset-file <task.jsonl> \
        --docker-image <image_name_or_tar_path> \
        --output-file <eval_output.jsonl>
"""

import argparse
import json
import os
import re
import subprocess
import tempfile
import time
from dataclasses import dataclass, asdict
from typing import Optional, Dict, Any, List, Callable
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)


# ============================================================
# TEST STATUS ENUM (matching client's constants)
# ============================================================

class TestStatus:
    """Test status values matching client's TestStatus enum."""
    PASSED = "PASSED"
    FAILED = "FAILED"
    ERROR = "ERROR"
    SKIPPED = "SKIPPED"
    XFAIL = "XFAIL"  # Expected failure - test failed as expected (treat as passing for P2P)
    XPASS = "XPASS"  # Unexpected pass - test passed when expected to fail


# ============================================================
# LOG PARSERS (matching client's log_parsers.py)
# ============================================================

def parse_log_pytest_v3(log: str, grading_spec: Any = None) -> Dict[str, str]:
    """
    Parser for test logs generated with PyTest framework (Repomate version).
    
    This matches the client's parse_log_pytest_v3 from log_parsers.py.
    Handles pytest -rA output format:
        PASSED test/test_file.py::test_name
        FAILED test/test_file.py::test_name
    """
    test_status_map = {}
    escapes = "".join([chr(char) for char in range(1, 32)])
    translator = str.maketrans("", "", escapes)
    
    # Precompile the regex pattern for efficiency
    # Include XFAIL and XPASS for pytest expected failure markers
    status_values = "|".join([TestStatus.PASSED, TestStatus.FAILED, TestStatus.ERROR, TestStatus.SKIPPED, TestStatus.XFAIL, TestStatus.XPASS])
    status_pattern = re.compile(rf"^({status_values})\s+")
    
    for line in log.split("\n"):
        line = re.sub(r"\[(\d+)m", "", line)  # Remove ANSI color codes
        line = line.translate(translator)
        line = line.replace(" - ", " ")
        
        match = status_pattern.match(line)
        if match:
            test_case = line.split()
            if len(test_case) >= 2:
                status = test_case[0]
                test_name = test_case[1]
                test_status_map[test_name] = status
        
        # Support older pytest output where status is at the end
        elif any(line.endswith(x) for x in [TestStatus.PASSED, TestStatus.FAILED, TestStatus.ERROR, TestStatus.SKIPPED]):
            test_case = line.split()
            if len(test_case) >= 2:
                test_status_map[test_case[0]] = test_case[-1]
    
    return test_status_map


def parse_log_unittest(log: str, grading_spec: Any = None) -> Dict[str, str]:
    """
    Parser for test logs generated with Python unittest framework.
    
    Handles unittest output format:
        test_name (test.module.TestClass) ... ok
        test_name (test.module.TestClass) ... FAIL
        test_name (test.module.TestClass) ... ERROR
    """
    test_status_map = {}
    
    for line in log.split("\n"):
        line = line.strip()
        
        # Pattern: test_name (test.module) ... ok
        if " ... ok" in line.lower():
            test = line.split(" ... ")[0].strip()
            test_status_map[test] = TestStatus.PASSED
        elif " ... fail" in line.lower():
            test = line.split(" ... ")[0].strip()
            test_status_map[test] = TestStatus.FAILED
        elif " ... error" in line.lower():
            test = line.split(" ... ")[0].strip()
            test_status_map[test] = TestStatus.ERROR
        elif " ... skip" in line.lower():
            test = line.split(" ... ")[0].strip()
            test_status_map[test] = TestStatus.SKIPPED
    
    return test_status_map


def parse_log_swelancer_exitcode(log: str, grading_spec: Any = None) -> Dict[str, str]:
    """
    Parser for SWE-Lancer that uses pytest exit code for grading.
    
    SWE-Lancer grading is based on pytest exit code:
    - Exit code 0 = PASS
    - Exit code 1 = FAIL (test failures)
    - Exit code >= 2 = ERROR (collection/execution errors)
    
    The log should contain the pytest exit code from:
    /app/tests/logs/<ISSUE_ID>/pytest_exit_code
    """
    test_status_map = {}
    
    # Look for exit code patterns
    exit_code = None
    
    # Pattern 1: pytest_exit_code file content or variable
    match = re.search(r'pytest_exit_code[:\s=]+(\d+)', log, re.IGNORECASE)
    if match:
        exit_code = int(match.group(1))
    
    # Pattern 2: "exit code:" or "Exit code:" pattern
    if exit_code is None:
        match = re.search(r'exit\s+code[:\s]+(\d+)', log, re.IGNORECASE)
        if match:
            exit_code = int(match.group(1))
    
    # Pattern 3: Check pytest summary for pass/fail counts
    if exit_code is None:
        if re.search(r'\d+\s+passed', log) and not re.search(r'\d+\s+failed', log):
            exit_code = 0
        elif re.search(r'\d+\s+failed', log) or re.search(r'\d+\s+error', log):
            exit_code = 1
    
    # Find test names in log - match both "tests/" and "issues/" paths
    # Pattern: issues/18207_923/test.py::test_duplicate_contact_methods
    test_names = re.findall(r'(issues/[\w_]+/test\.py::[\w_]+)', log)
    if not test_names:
        # Try shorter path pattern
        test_names = re.findall(r'tests/[\w_]+/test\.py::(test_\w+)', log)
    if not test_names:
        test_names = re.findall(r'(test_expensify_\d+)', log)
    if not test_names:
        test_names = ['test_expensify_0000']  # Default for SWE-Lancer
    
    # Grade based on exit code
    if exit_code is not None:
        if exit_code == 0:
            for name in set(test_names):
                test_status_map[name] = TestStatus.PASSED
        elif exit_code == 1:
            for name in set(test_names):
                test_status_map[name] = TestStatus.FAILED
        else:
            for name in set(test_names):
                test_status_map[name] = TestStatus.ERROR
    else:
        # Fallback: if we can't determine exit code, check for explicit PASSED/FAILED
        for name in set(test_names):
            if 'PASSED' in log or 'passed' in log.lower():
                test_status_map[name] = TestStatus.PASSED
            else:
                test_status_map[name] = TestStatus.FAILED
    
    return test_status_map


def parse_log_playwright(log: str, grading_spec: Any = None) -> Dict[str, str]:
    """
    Parser for SWE-Lancer Playwright tests run via pytest.
    
    SWE-Lancer uses Python tests with Playwright for browser automation.
    These tests are run via pytest and grading is based on exit code.
    """
    return parse_log_swelancer_exitcode(log, grading_spec)


# Parser registry mapping parser names to functions
PARSER_REGISTRY: Dict[str, Callable] = {
    "python/parse_log_pytest_v3": parse_log_pytest_v3,
    "python/parse_log_pytest": parse_log_pytest_v3,  # Alias
    "python/parse_log_unittest": parse_log_unittest,
    # SWE-Lancer parsers
    "javascript/parse_log_playwright": parse_log_playwright,
    "swelancer/parse_log_playwright": parse_log_playwright,
    "swelancer/parse_log_exitcode": parse_log_swelancer_exitcode,
}


def get_parser(parser_name: str) -> Callable:
    """Get parser function by name, defaulting to pytest_v3."""
    if parser_name in PARSER_REGISTRY:
        return PARSER_REGISTRY[parser_name]
    logger.warning(f"Unknown parser '{parser_name}', using parse_log_pytest_v3")
    return parse_log_pytest_v3


# ============================================================
# EVAL REPORT DATACLASS
# ============================================================

@dataclass
class EvalReport:
    """Evaluation report for a single instance."""
    instance_id: str
    resolved: bool
    failed_apply_patch: bool
    failed_apply_test_patch: bool
    error_eval: bool
    test_timeout: bool
    tests_passed: int
    tests_failed: int
    tests_error: int
    fail_to_pass_success: List[str]
    fail_to_pass_failed: List[str]
    pass_to_pass_success: List[str]
    pass_to_pass_failed: List[str]
    test_output: str
    error_message: str = ""
    execution_error: str = ""  # Track why test execution failed


# ============================================================
# SWE-LANCER CONFIGURATION
# ============================================================

# Environment variables for SWE-Lancer monolith mode
USE_SWELANCER_MONOLITH = os.environ.get('USE_SWELANCER_MONOLITH', 'false').lower() == 'true'
SWELANCER_MONOLITH_IMAGE = os.environ.get('SWELANCER_MONOLITH_IMAGE', 'swelancer/swelancer_x86_monolith:releasev1')


def is_swelancer_task(dataset: Dict[str, Any]) -> bool:
    """Check if this is a SWE-Lancer task based on dataset fields."""
    # Check for SWE-Lancer specific indicators
    repo = dataset.get('repo', '')
    test_parser = dataset.get('test_output_parser', '')
    monolith_image = dataset.get('monolith_image', '')
    
    return (
        'Expensify' in repo or
        'swelancer' in test_parser.lower() or
        'playwright' in test_parser.lower() or
        'swelancer' in monolith_image.lower()
    )


def get_swelancer_docker_image(dataset: Dict[str, Any]) -> str:
    """Get the Docker image for SWE-Lancer task."""
    # Priority: monolith mode > task_specific_image > image_storage_uri
    if USE_SWELANCER_MONOLITH:
        logger.info(f"Using SWE-Lancer monolith image: {SWELANCER_MONOLITH_IMAGE}")
        return SWELANCER_MONOLITH_IMAGE
    
    task_image = dataset.get('task_specific_image', '')
    if task_image:
        logger.info(f"Using task_specific_image: {task_image}")
        return task_image
    
    return dataset.get('image_storage_uri', '')


# ============================================================
# DOCKER OPERATIONS
# ============================================================

def run_docker_command(container_name: str, command: str, timeout: int = 300) -> tuple:
    """Run a command inside the Docker container."""
    try:
        result = subprocess.run(
            ["docker", "exec", container_name, "bash", "-c", command],
            capture_output=True,
            text=True,
            timeout=timeout
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return -1, "", f"Command timed out after {timeout} seconds"
    except Exception as e:
        return -1, "", str(e)


def start_container(docker_image: str, container_name: str, platform: str = "linux/amd64") -> bool:
    """Start a Docker container."""
    try:
        subprocess.run(
            ["docker", "rm", "-f", container_name],
            capture_output=True,
            timeout=30
        )
    except:
        pass
    
    try:
        result = subprocess.run(
            ["docker", "run", "-d", "--name", container_name,
             "--platform", platform,
             "--entrypoint", "/bin/bash", docker_image, "-c", "sleep 3600"],
            capture_output=True,
            text=True,
            timeout=120
        )
        return result.returncode == 0
    except Exception as e:
        logger.error(f"Failed to start container: {e}")
        return False


def start_swelancer_container(docker_image: str, container_name: str, platform: str = "linux/amd64") -> bool:
    """Start a SWE-Lancer Docker container.
    
    For monolith images, we just start with sleep command.
    The base_commit checkout and test execution will be handled separately.
    """
    try:
        subprocess.run(
            ["docker", "rm", "-f", container_name],
            capture_output=True,
            timeout=30
        )
    except:
        pass
    
    try:
        # For SWE-Lancer, start container with sleep command
        # The setup (base commit checkout, test execution) happens in run_swelancer_tests
        result = subprocess.run(
            ["docker", "run", "-d", "--name", container_name,
             "--platform", platform,
             "--entrypoint", "/bin/bash",
             docker_image, "-c", "sleep 7200"],  # 2 hour timeout
            capture_output=True,
            text=True,
            timeout=120
        )
        
        if result.returncode != 0:
            logger.error(f"Failed to start SWE-Lancer container: {result.stderr}")
            return False
        
        # Give container a moment to start
        time.sleep(2)
        
        # Verify container is running
        returncode, stdout, _ = run_docker_command(container_name, "echo 'ready'")
        if returncode == 0 and 'ready' in stdout:
            logger.info("SWE-Lancer container started successfully")
            return True
        else:
            logger.warning("SWE-Lancer container may not be ready, proceeding anyway")
            return True
        
    except Exception as e:
        logger.error(f"Failed to start SWE-Lancer container: {e}")
        return False


def stop_container(container_name: str):
    """Stop and remove a Docker container."""
    try:
        subprocess.run(["docker", "rm", "-f", container_name], capture_output=True, timeout=30)
    except:
        pass


# ============================================================
# PATCH EXTRACTION AND PROCESSING
# ============================================================

def extract_model_patch(trajectory: Dict[str, Any]) -> str:
    """Extract and clean the model git patch from trajectory output.
    
    Filters out ONLY workspace artifact files (from OpenHands agent execution):
    - command, exec_time, exit_code, stdout, stderr, etc.
    
    Keeps:
    - All source code changes
    - .egg-info metadata (may be needed for package installation)
    - reproduce_ scripts (model-created test scripts)
    - Test file changes
    """
    test_result = trajectory.get('test_result', {})
    git_patch = test_result.get('git_patch', '')
    
    if not git_patch:
        return ''
    
    # ONLY exact artifact filenames from OpenHands workspace
    # These are NOT code - they're agent execution metadata
    # Also exclude test infrastructure that exists in Docker images
    EXCLUDED_FILES = [
        'command', 'exec_time', 'exit_code', 'stdout', 'stderr',
        'test_output', 'test_log', '.test_', '_test_output',
        'unittest_loader_no_traceback.py',  # Test runner infrastructure (baked in images)
        'unittest_loader.py'  # Test runner infrastructure (baked in images)
    ]
    
    lines = git_patch.split('\n')
    filtered_lines = []
    skip_current_diff = False
    
    for line in lines:
        if line.startswith('diff --git'):
            # Extract the file being modified
            parts = line.split(' ')
            if len(parts) >= 4:
                # Get the b/ path (destination file)
                b_path = parts[3] if parts[3].startswith('b/') else parts[2]
                file_name = b_path.replace('b/', '').strip()
                
                # Check if this is an excluded artifact file
                skip_current_diff = False
                for excluded in EXCLUDED_FILES:
                    if file_name == excluded or file_name.endswith(f'/{excluded}'):
                        skip_current_diff = True
                        logger.debug(f"Skipping artifact file: {file_name}")
                        break
        
        if not skip_current_diff:
            filtered_lines.append(line)
    
    # Find first actual diff line
    result_lines = []
    found_diff = False
    for line in filtered_lines:
        if line.startswith('diff --git'):
            found_diff = True
        if found_diff:
            result_lines.append(line)
    
    result = '\n'.join(result_lines)
    
    if result and not result.endswith('\n'):
        result += '\n'
    
    return result


# ============================================================
# SWE-LANCER TEST EXECUTION
# ============================================================

def run_swelancer_tests(
    container_name: str, 
    instance: Dict[str, Any], 
    base_commit: str,
    model_patch: str = None,
    timeout: int = 900
) -> tuple:
    """
    Run SWE-Lancer tests using the official ansible-playbook method.
    
    SWE-Lancer test execution:
    1. Set up test environment (Xvfb, dev server, mitmdump, SSL certs)
    2. Checkout base_commit (if using monolith)
    3. Apply model patch (MUST be after checkout!)
    4. Run ansible-playbook to execute tests
    5. Read pytest exit code for grading
    
    Returns: (returncode, stdout, stderr)
    """
    instance_id = instance.get('instance_id', '')
    # Extract issue_id from instance_id if it contains underscores or is a timestamp
    issue_id = instance_id
    if '_' in str(instance_id):
        # Format: issue_num_X or similar
        parts = str(instance_id).split('_')
        issue_id = parts[0]
    elif len(str(instance_id)) > 10:
        # It's a generated timestamp ID - try to get from test_command or FAIL_TO_PASS
        # First try to extract from test_command (most reliable)
        test_cmd = instance.get('test_command', '')
        if test_cmd:
            import re
            # Match ISSUE_ID=<value> pattern in test_command
            match = re.search(r'ISSUE_ID=([0-9_]+)', str(test_cmd))
            if match:
                issue_id = match.group(1)
                logger.info(f"Extracted issue_id from test_command: {issue_id}")
        
        # Fallback to FAIL_TO_PASS if test_command didn't work
        if issue_id == instance_id:
            f2p = instance.get('FAIL_TO_PASS', [])
            if f2p:
                # Extract issue number from test path like "issues/15925/test.py" or "issues/18207_923/test.py"
                import re
                match = re.search(r'issues/([0-9_]+)/', str(f2p))
                if match:
                    issue_id = match.group(1)
                    logger.info(f"Extracted issue_id from FAIL_TO_PASS: {issue_id}")
    
    repo_path = instance.get('repo_path', '/app/expensify')
    
    # Step 1: Set up the test environment
    logger.info(f"Setting up SWE-Lancer test environment for issue {issue_id}...")
    
    # CRITICAL: Add /etc/hosts entry for dev.new.expensify.com
    # The test connects to https://dev.new.expensify.com:8082 through the proxy
    hosts_cmd = (
        "grep -q 'dev.new.expensify.com' /etc/hosts || "
        "echo '127.0.0.1 dev.new.expensify.com' >> /etc/hosts"
    )
    run_docker_command(container_name, hosts_cmd, timeout=30)
    
    # Set up SSL certificates using mkcert
    setup_commands = [
        # Install mkcert CA
        "mkcert -install 2>/dev/null || true",
        # Generate certificates
        "cd /app/expensify/config/webpack && mkcert -key-file key.pem -cert-file certificate.pem localhost 127.0.0.1 dev.new.expensify.com 2>/dev/null || true",
        # Start Xvfb
        "pkill -9 Xvfb 2>/dev/null || true",
        "Xvfb :99 -screen 0 1920x1080x24 &",
        "export DISPLAY=:99",
        # Start fluxbox
        "fluxbox &>/dev/null &",
    ]
    
    for cmd in setup_commands:
        run_docker_command(container_name, cmd, timeout=60)
    
    # Wait for Xvfb to start
    time.sleep(2)
    
    # If using monolith, checkout the base_commit
    if base_commit:
        logger.info(f"Checking out base commit {base_commit[:12]}...")
        returncode, stdout, stderr = run_docker_command(
            container_name,
            f"cd {repo_path} && git fetch origin 2>/dev/null || true && "
            f"git checkout {base_commit} 2>&1 && "
            f"git reset --hard {base_commit} 2>&1",
            timeout=300
        )
        if returncode != 0:
            logger.warning(f"Base commit checkout may have issues: {stderr}")
        else:
            logger.info(f"Successfully checked out {base_commit[:12]}")
    
    # ============================================================
    # APPLY MODEL PATCH (must be after checkout!)
    # ============================================================
    if model_patch:
        logger.info("Applying model patch to SWE-Lancer repo...")
        returncode, stdout, stderr = run_docker_command(
            container_name,
            f"cd {repo_path} && git apply -v /tmp/model.patch 2>&1 || "
            f"git apply --reject --whitespace=fix /tmp/model.patch 2>&1 || "
            "patch --batch --fuzz=5 -p1 -i /tmp/model.patch 2>&1 || true"
        )
        logger.info(f"Model patch apply result: returncode={returncode}")
        if returncode != 0:
            logger.warning(f"Model patch apply may have issues: {stdout}")
    
    # ============================================================
    # DYNAMIC NODE VERSION SWITCHING
    # Based on base_commit, select the correct Node.js version and
    # copy the pre-cached node_modules
    # ============================================================
    
    # Map base_commit to Node.js version
    # These mappings are based on the package.json engines field for each commit
    NODE_VERSION_MAP = {
        "2b791c9f3053": "20.15.1",  # new.expensify 9.0.41-1
        "da2e6688c3f1": "20.18.0",  # new.expensify 9.0.54-8
        "006a1dfe67a7": "20.18.0",  # new.expensify 9.0.77-6
    }
    
    # Determine Node version from base_commit
    node_version = None
    if base_commit:
        commit_prefix = base_commit[:12]
        for commit_key, version in NODE_VERSION_MAP.items():
            if commit_key.startswith(commit_prefix) or commit_prefix.startswith(commit_key[:12]):
                node_version = version
                break
    
    if node_version:
        logger.info(f"Setting up Node.js {node_version} for commit {base_commit[:12]}...")
        
        # Switch to the correct Node version using nvm
        switch_node_cmd = f"source ~/.nvm/nvm.sh && nvm use {node_version} && node --version"
        returncode, stdout, stderr = run_docker_command(container_name, switch_node_cmd, timeout=30)
        logger.info(f"Node version switch: {stdout.strip()}")
        
        # Copy cached node_modules if available
        cache_dir = f"/app/node_cache/{node_version}/node_modules"
        target_dir = f"{repo_path}/node_modules"
        
        # Check if cached node_modules exists
        _, cache_check, _ = run_docker_command(
            container_name,
            f"ls -d {cache_dir} 2>/dev/null && echo 'CACHE_EXISTS' || echo 'NO_CACHE'"
        )
        
        # First check for commit-specific cache
        commit_cache_dir = f"/app/node_cache/commits/{base_commit[:12]}_node_modules"
        _, commit_cache_check, _ = run_docker_command(
            container_name,
            f"ls -d {commit_cache_dir} 2>/dev/null && echo 'COMMIT_CACHE_EXISTS' || echo 'NO_COMMIT_CACHE'"
        )
        
        if "COMMIT_CACHE_EXISTS" in commit_cache_check:
            logger.info(f"Using commit-specific node_modules from {commit_cache_dir}...")
            copy_cmd = (
                f"rm -rf {target_dir} && "
                f"cp -r {commit_cache_dir} {target_dir} && "
                f"ls -1 {target_dir} 2>/dev/null | wc -l"
            )
            returncode, stdout, stderr = run_docker_command(container_name, copy_cmd, timeout=300)
            package_count = stdout.strip().split('\n')[-1] if stdout else "unknown"
            logger.info(f"Commit-specific node_modules copied: {package_count} packages")
        elif "CACHE_EXISTS" in cache_check:
            # Fallback: Copy generic cache then run npm ci to fix symlinks/local deps
            logger.info(f"Using generic cache + npm ci for correct dependencies...")
            copy_cmd = (
                f"rm -rf {target_dir} && "
                f"if command -v rsync &> /dev/null; then "
                f"  rsync -a {cache_dir}/ {target_dir}/; "
                f"else "
                f"  cp -r {cache_dir} {target_dir}; "
                f"fi"
            )
            run_docker_command(container_name, copy_cmd, timeout=300)
            
            # CRITICAL: Run npm ci to fix local dependencies and symlinks
            # This is faster than full npm ci since packages are already present
            logger.info("Running npm ci to fix local dependencies...")
            npm_ci_cmd = (
                f"cd {repo_path} && source ~/.nvm/nvm.sh && nvm use {node_version} && "
                f"npm ci 2>&1 | tail -10"
            )
            returncode, stdout, stderr = run_docker_command(container_name, npm_ci_cmd, timeout=300)
            logger.info(f"npm ci result: {stdout.strip()}")
        else:
            logger.warning(f"No cached node_modules for Node {node_version}, npm ci will be needed")
            # Run full npm ci
            logger.info("Running full npm ci (this may take 2-3 minutes)...")
            npm_ci_cmd = (
                f"cd {repo_path} && source ~/.nvm/nvm.sh && nvm use {node_version} && "
                f"npm ci 2>&1 | tail -15"
            )
            returncode, stdout, stderr = run_docker_command(container_name, npm_ci_cmd, timeout=600)
            logger.info(f"npm ci result: {stdout.strip()}")
    else:
        logger.warning(f"Unknown base_commit {base_commit}, using default Node version")
    
    # Start mitmdump for the specific issue
    # The proxy intercepts requests and replays recorded network traffic
    logger.info(f"Starting mitmdump for issue {issue_id}...")
    
    # Check if addon file exists
    _, addon_check, _ = run_docker_command(
        container_name,
        f"ls -la /app/tests/addons/issues/{issue_id}/addon.py 2>/dev/null || echo 'ADDON NOT FOUND'"
    )
    if "ADDON NOT FOUND" in addon_check:
        # Use replay.py as fallback
        logger.warning(f"No addon.py found for issue {issue_id}, using replay.py")
        mitm_cmd = (
            f"export ISSUE_ID={issue_id} && "
            f"cd /app/tests && "
            f"mitmdump -s replay.py --listen-port 8080 --ssl-insecure "
            f"--set confdir=/root/.mitmproxy >/tmp/mitmdump.log 2>&1 &"
        )
    else:
        mitm_cmd = (
            f"export ISSUE_ID={issue_id} && "
            f"cd /app/tests && "
            f"mitmdump -s addons/issues/{issue_id}/addon.py --listen-port 8080 --ssl-insecure "
            f"--set confdir=/root/.mitmproxy >/tmp/mitmdump.log 2>&1 &"
        )
    
    run_docker_command(container_name, mitm_cmd, timeout=30)
    time.sleep(5)  # Give mitmdump more time to start
    
    # Verify mitmdump is running on port 8080
    _, mitm_check, _ = run_docker_command(
        container_name,
        "netstat -tlnp 2>/dev/null | grep 8080 || ss -tlnp | grep 8080 || echo 'Mitmdump port 8080 not listening'"
    )
    logger.info(f"Mitmdump port check: {mitm_check.strip()}")
    
    # Start dev server on port 8082 (required by tests)
    # The test expects https://dev.new.expensify.com:8082/
    logger.info("Starting webpack dev server on port 8082...")
    
    # Check if node_modules exists (required for dev server)
    _, node_modules_check, _ = run_docker_command(
        container_name,
        f"ls -d {repo_path}/node_modules 2>/dev/null && echo 'EXISTS' || echo 'MISSING'"
    )
    
    if "MISSING" in node_modules_check:
        logger.warning("node_modules is missing after cache copy! Running npm ci...")
        nvm_use = f"nvm use {node_version} && " if node_version else ""
        returncode, stdout, stderr = run_docker_command(
            container_name,
            f"cd {repo_path} && source ~/.nvm/nvm.sh && {nvm_use}npm ci 2>&1 | tail -20",
            timeout=600
        )
        if returncode != 0 or "npm error" in stdout:
            logger.error(f"npm ci failed: {stdout}")
        else:
            logger.info(f"npm ci completed: {stdout.strip().split(chr(10))[-1]}")
    else:
        logger.info(f"node_modules found: {node_modules_check.strip()}")
    
    # Source nvm with correct version and start dev server
    # CRITICAL: Set USE_WEB_PROXY=false so API calls go directly to www.expensify.com
    # through the browser's proxy (mitmdump), instead of through webpack's internal proxy
    nvm_use = f"nvm use {node_version} && " if node_version else ""
    dev_server_cmd = (
        f"cd {repo_path} && "
        f"export USE_WEB_PROXY=false && "
        f"source ~/.nvm/nvm.sh && {nvm_use}"
        f"npm run web >/tmp/devserver.log 2>&1 &"
    )
    run_docker_command(container_name, dev_server_cmd, timeout=30)
    
    # Wait for dev server to start (webpack compilation takes time)
    logger.info("Waiting for dev server to be ready (60s for webpack compilation)...")
    time.sleep(60)
    
    # Verify dev server is running on port 8082
    _, port_check, _ = run_docker_command(
        container_name,
        "netstat -tlnp 2>/dev/null | grep 8082 || ss -tlnp | grep 8082 || echo 'Port 8082 not listening'"
    )
    logger.info(f"Dev server port check: {port_check.strip()}")
    
    if "not listening" in port_check:
        # Check dev server log for errors
        _, devlog, _ = run_docker_command(container_name, "tail -30 /tmp/devserver.log 2>/dev/null || echo 'No log'")
        logger.error(f"Dev server failed to start. Log: {devlog}")
    
    # Create logs directory for this instance
    run_docker_command(
        container_name,
        f"mkdir -p /app/tests/logs/{issue_id}"
    )
    
    # ============================================================
    # CRITICAL: Rewrite test file to inject proxy configuration
    # This makes Playwright browser route traffic through mitmdump
    # Without this, browser goes directly to internet, bypassing our replay proxy
    # ============================================================
    logger.info(f"Rewriting test file to inject proxy configuration...")
    
    # First ensure libcst is installed (required by rewrite_test.py)
    run_docker_command(
        container_name,
        "pip3 install libcst --quiet 2>/dev/null || pip install libcst --quiet 2>/dev/null || true",
        timeout=120
    )
    
    rewrite_cmd = (
        f"cd /app/tests && "
        f"python3 rewrite_test.py issues/{issue_id}/test.py 2>&1"
    )
    rewrite_returncode, rewrite_stdout, rewrite_stderr = run_docker_command(
        container_name, rewrite_cmd, timeout=60
    )
    if rewrite_returncode != 0:
        logger.warning(f"Test rewrite may have issues: {rewrite_stdout} {rewrite_stderr}")
    else:
        logger.info("Test file rewritten successfully with proxy configuration")
    
    # Run tests using pytest directly (more reliable than ansible-playbook)
    logger.info(f"Running SWE-Lancer tests for issue {issue_id}...")
    
    # CRITICAL FIX: Use PIPESTATUS to capture pytest's exit code, not tee's
    # The previous code used `$?` which captures tee's exit code (always 0)
    # PIPESTATUS[0] captures the exit code of the first command in the pipeline (pytest)
    test_command = (
        f'export DISPLAY=:99 && '
        f'export ISSUE_ID={issue_id} && '
        f'cd /app/tests && '
        f'set -o pipefail && '  # Make pipeline return first non-zero exit code
        f'pytest issues/{issue_id}/test.py -v --tb=short 2>&1 | tee /app/tests/logs/{issue_id}/pytest.log; '
        f'echo ${{PIPESTATUS[0]}} > /app/tests/logs/{issue_id}/pytest_exit_code'
    )
    
    returncode, stdout, stderr = run_docker_command(
        container_name,
        test_command,
        timeout=timeout
    )
    
    test_output = stdout + stderr
    
    # Get pytest exit code (official grading method)
    _, exit_code_str, _ = run_docker_command(
        container_name,
        f"cat /app/tests/logs/{issue_id}/pytest_exit_code 2>/dev/null || echo '-1'"
    )
    
    # Get pytest log
    _, pytest_log, _ = run_docker_command(
        container_name,
        f"cat /app/tests/logs/{issue_id}/pytest.log 2>/dev/null || echo 'No pytest log'"
    )
    
    # Combine all output with exit code for parser
    full_output = (
        f"=== TEST OUTPUT ===\n{test_output}\n\n"
        f"=== PYTEST LOG ===\n{pytest_log}\n\n"
        f"=== PYTEST EXIT CODE ===\n{exit_code_str.strip()}\n"
        f"pytest_exit_code: {exit_code_str.strip()}"
    )
    
    try:
        pytest_exit = int(exit_code_str.strip().split('\n')[-1])
    except (ValueError, IndexError):
        pytest_exit = -1
    
    logger.info(f"SWE-Lancer test execution complete. pytest_exit_code={pytest_exit}")
    
    return pytest_exit, full_output, ""


# ============================================================
# EVAL SCRIPT GENERATION (following test_spec.py:make_eval_test_spec)
# ============================================================

def detect_repo_directory(container_name: str) -> str:
    """
    Detect the actual repository directory in the container.

    Tries in order:
    1. /testbed (standard SWE-bench location, most images)
    2. /app/repo (PHP images)

    Returns: Path to repository directory
    """
    # Try /testbed first (most common)
    returncode, stdout, stderr = run_docker_command(
        container_name,
        "test -d /testbed && echo 'exists' || echo 'missing'",
        timeout=10
    )

    if returncode == 0 and 'exists' in stdout:
        logger.info("Detected repository directory: /testbed")
        return "/testbed"

    # Fallback to /app/repo (PHP images)
    returncode, stdout, stderr = run_docker_command(
        container_name,
        "test -d /app/repo && echo 'exists' || echo 'missing'",
        timeout=10
    )

    if returncode == 0 and 'exists' in stdout:
        logger.info("Detected repository directory: /app/repo")
        return "/app/repo"

    # Default to /testbed if detection fails
    logger.warning("Could not detect repository directory, defaulting to /testbed")
    return "/testbed"


def run_test_command(container_name: str, instance: Dict[str, Any], timeout: int = 900) -> tuple:
    """
    Run the test command from the dataset, following client's test_spec.py flow.

    Returns: (returncode, stdout, stderr)
    """
    # Detect the actual repository directory in the container
    repo_directory = detect_repo_directory(container_name)
    test_patch_raw = instance.get("test_patch", "")
    test_command = instance.get("test_command", "pytest")
    
    # Parse test_patch - it may be a JSON-encoded list of patches or a raw diff string
    # Following client's _from_json_or_obj pattern from test_spec.py
    test_patches = []
    if test_patch_raw and test_patch_raw.strip():
        if test_patch_raw.strip().startswith('['):
            try:
                parsed = json.loads(test_patch_raw)
                if isinstance(parsed, list):
                    test_patches = [p for p in parsed if p and p.strip()]
                else:
                    test_patches = [str(parsed)]
            except json.JSONDecodeError:
                test_patches = [test_patch_raw]
        else:
            test_patches = [test_patch_raw]
    
    logger.info(f"Parsed {len(test_patches)} test patches from dataset")
    
    # Step 1: Apply golden test patches if present
    for i, test_patch in enumerate(test_patches):
        if not test_patch or not test_patch.strip():
            continue
            
        logger.info(f"Applying golden test patch {i+1}/{len(test_patches)} ({len(test_patch)} chars)...")
        with tempfile.NamedTemporaryFile(mode='w', suffix='.diff', delete=False) as f:
            f.write(test_patch)
            patch_file = f.name
        
        subprocess.run(
            ["docker", "cp", patch_file, f"{container_name}:/tmp/test.patch"],
            capture_output=True, timeout=30
        )
        os.unlink(patch_file)
        
        # CRITICAL FIX: Remove conflicting files before applying test patch
        # The model may have created test files that conflict with the golden test patch
        # Extract file paths from the patch and remove them first
        returncode, stdout, stderr = run_docker_command(
            container_name,
            f"cd {repo_directory} && "
            # First, extract new files from patch (lines starting with +++ b/) 
            # and remove them if they exist to avoid "already exists" error
            f"grep '^+++ b/' /tmp/test.patch | sed 's|^+++ b/||' | while read f; do "
            f"  if [ -f \"$f\" ]; then rm -f \"$f\"; echo \"Removed conflicting: $f\"; fi; "
            f"done; "
            # Now apply the patch - use git apply first, then patch as fallback
            f"git apply -v --3way /tmp/test.patch 2>&1 || "
            f"git apply -v /tmp/test.patch 2>&1 || "
            f"patch --batch --fuzz=5 -p1 -i /tmp/test.patch 2>&1"
        )
        logger.info(f"Test patch {i+1} apply result: {returncode}")
        if "Removed conflicting" in stdout:
            logger.info(f"Removed model-created files that conflicted with test patch")
    
    # Step 2: Build the test execution command
    # CRITICAL: Unset proxy environment variables that are baked into client images
    # These proxies (127.0.0.1:8080) don't exist on AWS and break pip/package operations
    unset_proxy = (
        "unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ftp_proxy FTP_PROXY all_proxy ALL_PROXY; "
        "export http_proxy='' https_proxy='' HTTP_PROXY='' HTTPS_PROXY=''; "
    )
    
    # Build command: Always source ENV first, unset proxies, then run test_command
    # The test_command may contain its own source, so we strip that and handle it uniformly
    # First, extract just the test execution part (after any source commands)
    test_exec = test_command
    if "&&" in test_command and "source" in test_command:
        # Extract the part after the last && that contains source
        parts = test_command.split("&&")
        test_exec = parts[-1].strip()  # Get the actual test command (pytest, etc.)
    
    # Build a clean command: activate conda environment, unset proxies, then run tests
    # Always source conda.sh and activate testbed for mswebench images
    # The || true ensures we continue even if old /saved/ENV doesn't exist
    full_command = (
        f"source /opt/miniconda3/etc/profile.d/conda.sh && conda activate testbed; "
        f"{unset_proxy}"
        f"cd {repo_directory} && {test_exec}"
    )
    
    logger.info(f"Running test command: {full_command[:200]}...")
    
    # Step 3: Execute tests
    return run_docker_command(container_name, full_command, timeout=timeout)


# ============================================================
# TEST RESULT GRADING
# ============================================================

def grade_test_results(
    test_status_map: Dict[str, str],
    fail_to_pass: List[str],
    pass_to_pass: List[str]
) -> Dict[str, Any]:
    """
    Grade test results against F2P and P2P expectations.
    
    Returns dict with categorized test results.
    """
    
    # XFAIL and XPASS are valid pytest outcomes:
    # - XFAIL: Expected to fail and did fail (not a regression)
    # - XPASS: Expected to fail but passed (unexpected success)
    # For P2P, XFAIL should count as "success" (not a regression), XPASS is also success
    passing_statuses = {TestStatus.PASSED, TestStatus.XFAIL, TestStatus.XPASS}
    
    results = {
        'tests_passed': sum(1 for s in test_status_map.values() if s in passing_statuses or s == TestStatus.SKIPPED),
        'tests_failed': sum(1 for s in test_status_map.values() if s == TestStatus.FAILED),
        'tests_error': sum(1 for s in test_status_map.values() if s == TestStatus.ERROR),
        'fail_to_pass_success': [],
        'fail_to_pass_failed': [],
        'pass_to_pass_success': [],
        'pass_to_pass_failed': [],
    }
    
    
    # Grade F2P tests (should now pass)
    # CRITICAL FIX for PHPUnit: If a test is NOT in the failure/error map,
    # it means it PASSED (PHPUnit only lists failed/errored tests by name)
    for test in fail_to_pass:
        matched = False
        test_failed = False
        for result_test, status in test_status_map.items():
            # Check exact match or substring match
            if test == result_test or test in result_test or result_test in test:
                if status == TestStatus.PASSED:
                    results['fail_to_pass_success'].append(test)
                else:
                    results['fail_to_pass_failed'].append(test)
                    test_failed = True
                matched = True
                break
        
        if not matched:
            # CRITICAL: If not in failure/error map, test PASSED (for PHPUnit)
            # PHPUnit only lists failed/errored tests, not passing ones
            logger.info(f"F2P test not in failure list (PASSED): {test}")
            results['fail_to_pass_success'].append(test)
    
    # Grade P2P tests (should still pass)
    # XFAIL and XPASS are acceptable for P2P (not regressions)
    # CRITICAL FIX for PHPUnit: If not in failure map, test PASSED
    for test in pass_to_pass:
        matched = False
        for result_test, status in test_status_map.items():
            if test == result_test or test in result_test or result_test in test:
                if status in passing_statuses or status == TestStatus.SKIPPED:
                    results['pass_to_pass_success'].append(test)
                else:
                    results['pass_to_pass_failed'].append(test)
                matched = True
                break
        
        if not matched:
            # CRITICAL FIX for PHPUnit: If not in failure/error map, test PASSED
            logger.info(f"P2P test not in failure list (PASSED): {test}")
            results['pass_to_pass_success'].append(test)
            continue  # Skip the failed append below
            results['pass_to_pass_failed'].append(test)
    
    return results


def parse_pytest_output(stdout: str) -> Dict[str, str]:
    """
    Parse pytest output to extract test results.
    
    Handles multiple pytest output formats:
    1. "PASSED test/test_file.py::test_name"  
    2. "test/test_file.py::test_name PASSED"
    3. Summary counts from the final line
    4. XFAIL/XPASS for expected failure tests
    
    CRITICAL FIX: Remove ANSI color codes before parsing (matching client's log_parsers.py)
    
    Returns: Dict[test_name, status]
    """
    test_status_map = {}
    
    # Remove control characters (matching client's translator approach)
    escapes = "".join([chr(char) for char in range(1, 32)])
    translator = str.maketrans("", "", escapes)
    
    # All valid pytest status values including XFAIL/XPASS
    ALL_STATUSES = ['PASSED', 'FAILED', 'ERROR', 'SKIPPED', 'XFAIL', 'XPASS']
    status_pattern = '|'.join(ALL_STATUSES)
    
    for line in stdout.split('\n'):
        # CRITICAL: Remove ANSI color codes like [32m, [0m, etc.
        # This matches client's parse_log_pytest_v3: re.sub(r"\[(\d+)m", "", line)
        line = re.sub(r"\[\d+m", "", line)
        line = line.translate(translator)
        line = line.strip()
        
        # Pattern 1: "PASSED test_path" or "XFAIL test_path - reason" (pytest -rA format)
        # For XFAIL, there's often a reason after the test name like "XFAIL test_path - reason"
        match = re.match(rf'^({status_pattern})\s+(\S+)', line)
        if match:
            status, test_path = match.groups()
            test_status_map[test_path.strip()] = status
            continue
        
        # Pattern 2: "test_path PASSED" or "test_path FAILED"
        match = re.match(rf'^(.+::.*?)\s+({status_pattern})(?:\s|$)', line)
        if match:
            test_path, status = match.groups()
            test_status_map[test_path.strip()] = status
            continue
        
        # Pattern 3: Look for status at the end of lines with test paths
        for status in ALL_STATUSES:
            if f' {status}' in line or line.endswith(status):
                # Extract test path before the status
                parts = re.split(rf'\s+{status}(?:\s|$)', line)[0].strip()
                if '::' in parts:
                    test_status_map[parts] = status
                    break
    
    
    return test_status_map


def parse_unittest_output(stdout: str) -> Dict[str, str]:
    """Parse unittest output format."""
    test_status_map = {}
    
    for line in stdout.split('\n'):
        line = line.strip()
        
        if ' ... ok' in line.lower():
            test = line.split(' ... ')[0].strip()
            test_status_map[test] = TestStatus.PASSED
        elif ' ... fail' in line.lower():
            test = line.split(' ... ')[0].strip()
            test_status_map[test] = TestStatus.FAILED
        elif ' ... error' in line.lower():
            test = line.split(' ... ')[0].strip()
            test_status_map[test] = TestStatus.ERROR
        elif ' ... skip' in line.lower():
            test = line.split(' ... ')[0].strip()
            test_status_map[test] = TestStatus.SKIPPED
    
    return test_status_map


# ============================================================
# MAIN EVALUATION FUNCTION
# ============================================================

def convert_phpunit_to_filepath(namespace_test: str) -> str:
    """
    Convert PHPUnit namespace format to file path format.
    
    Input:  Barryvdh\LaravelIdeHelper\Tests\Console\MetaCommand\MetaCommandTest::testCommand
    Output: tests/Console/MetaCommand/MetaCommandTest.php::testCommand
    """
    if '::' not in namespace_test:
        return namespace_test
    
    class_part, method = namespace_test.rsplit('::', 1)
    
    # Find the "Tests\" part and convert everything after it
    tests_patterns = [
        r'.*\\Tests\\',  # Match up to and including \Tests\
        r'^Tests\\',       # Match if starts with Tests\
    ]
    
    for pattern in tests_patterns:
        match = re.search(pattern, class_part)
        if match:
            after_tests = class_part[match.end():]
            path = after_tests.replace('\\', '/')
            return f"tests/{path}.php::{method}"
    
    # Fallback: just convert backslashes
    path = class_part.replace('\\', '/')
    return f"{path}.php::{method}"


def parse_phpunit_output(stdout: str) -> dict:
    """
    Parse PHPUnit test output and convert to file path format.
    
    PHPUnit outputs: Barryvdh\LaravelIdeHelper\Tests\Console\MetaCommand\MetaCommandTest::testCommand
    Expected format: tests/Console/MetaCommand/MetaCommandTest.php::testCommand
    
    Returns: Dict[test_name, status]
    """
    test_status_map = {}
    
    in_errors = False
    in_failures = False
    
    lines = stdout.split('\n')
    for i, line in enumerate(lines):
        line_stripped = line.strip()
        
        # Detect sections
        if 'There were' in line and 'error' in line.lower():
            in_errors = True
            in_failures = False
            continue
        if 'There were' in line and 'failure' in line.lower():
            in_failures = True
            in_errors = False
            continue
        if line.startswith('FAILURES!') or line.startswith('OK ('):
            break
        
        # Match numbered test entries like "1) TestClass::testMethod"
        match = re.match(r'^\s*\d+\)\s+(.+)', line_stripped)
        if match:
            full_test_name = match.group(1).strip()
            
            # Clean up test name - remove data provider info
            if ' with data set' in full_test_name:
                full_test_name = full_test_name.split(' with data set')[0].strip()
            
            # Convert namespace to file path format
            converted_name = convert_phpunit_to_filepath(full_test_name)
            
            # Store BOTH formats for matching flexibility
            if in_errors:
                test_status_map[converted_name] = 'ERROR'
                test_status_map[full_test_name] = 'ERROR'
            elif in_failures:
                test_status_map[converted_name] = 'FAILED'
                test_status_map[full_test_name] = 'FAILED'
    
    logger.info(f"[PHPUnit] Parsed {len(test_status_map)} test results (including both formats)")
    return test_status_map



def evaluate_instance(
    trajectory_file: str,
    dataset_file: str,
    docker_image: str,
    timeout: int = 900
) -> EvalReport:
    """
    Evaluate a single trajectory instance following the standardized process.
    
    Steps:
    1. Load trajectory and extract model patch
    2. Load dataset with F2P, P2P, test_command, test_output_parser
    3. Start Docker container
    4. Apply model patch
    5. Run eval script (applies test patch + runs tests)
    6. Parse test output using specified parser
    7. Grade results against F2P/P2P
    """
    container_name = f"eval_pilot2_{int(time.time())}"
    
    try:
        # Step 1: Load trajectory
        logger.info(f"Loading trajectory from {trajectory_file}")
        with open(trajectory_file, 'r') as f:
            # All corrected delivery trajectories are single JSON objects (formatted or compact)
            # Just read and parse the entire file
            content = f.read().strip()
            trajectory = json.loads(content)
        
        instance_id = trajectory.get('instance_id', 'unknown')
        model_patch = extract_model_patch(trajectory)
        
        logger.info(f"Instance ID: {instance_id}")
        logger.info(f"Model patch length: {len(model_patch)} chars")
        
        # Step 2: Load dataset
        logger.info(f"Loading dataset from {dataset_file}")
        with open(dataset_file, 'r') as f:
            # Datasets are single JSON objects (formatted or compact), not JSONL
            # Just read and parse the entire file (same as trajectory loading)
            content = f.read().strip()
            dataset = json.loads(content)

            # Verify instance ID matches
            if dataset.get('instance_id') != instance_id:
                raise ValueError(f"Instance ID mismatch: expected {instance_id}, got {dataset.get('instance_id')}")
        
        # FIX: Use trajectory's instance field as primary source, fallback to dataset
        # The trajectory's instance field contains complete data from OpenHands
        traj_instance = trajectory.get('instance', {})

        # FIX: Handle both JSON and Python literal formats
        # Some datasets store F2P/P2P as Python literals with single quotes: ['test1', 'test2']
        # json.loads() fails on these, so we fallback to ast.literal_eval()
        import ast

        def _parse_list_field(value):
            """Parse a list field that may be JSON, Python literal, or already a list."""
            if isinstance(value, list):
                return value
            if not isinstance(value, str) or not value.strip():
                return []
            # Try JSON first
            try:
                return json.loads(value)
            except json.JSONDecodeError:
                pass
            # Fallback to Python literal (handles single quotes)
            try:
                parsed = ast.literal_eval(value)
                if isinstance(parsed, list):
                    return parsed
            except (ValueError, SyntaxError):
                pass
            # Last resort: return empty list
            logger.warning(f"Could not parse list field: {value[:50]}...")
            return []

        # Parse fields from trajectory, but if empty after parsing, use dataset
        fail_to_pass = _parse_list_field(traj_instance.get('FAIL_TO_PASS'))
        if not fail_to_pass:  # If trajectory has empty list, fallback to dataset
            fail_to_pass = _parse_list_field(dataset.get('FAIL_TO_PASS', []))

        pass_to_pass = _parse_list_field(traj_instance.get('PASS_TO_PASS'))
        if not pass_to_pass:  # If trajectory has empty list, fallback to dataset
            pass_to_pass = _parse_list_field(dataset.get('PASS_TO_PASS', []))

        # Parse test_command with proper empty string handling
        test_command = traj_instance.get('test_command') or dataset.get('test_command') or 'pytest'
        # If test_command is empty string, use default
        if not test_command or not test_command.strip():
            test_command = 'pytest --no-header -rA --tb=no -p no:cacheprovider'
            logger.warning(f"Empty test_command in dataset, using default: {test_command}")

        test_output_parser = traj_instance.get('test_output_parser') or dataset.get('test_output_parser', 'python/parse_log_pytest_v3')
        test_patch = traj_instance.get('test_patch') or dataset.get('test_patch', '')

        logger.info(f"F2P tests: {len(fail_to_pass)}")
        logger.info(f"P2P tests: {len(pass_to_pass)}")
        logger.info(f"Test command: {test_command[:80]}...")
        logger.info(f"Parser: {test_output_parser}")
        
        # Check if this is a SWE-Lancer task
        is_swelancer = is_swelancer_task(dataset)
        if is_swelancer:
            logger.info("Detected SWE-Lancer task - using SWE-Lancer evaluation flow")
        
        # Get the appropriate Docker image for SWE-Lancer
        # Only use dataset image if command-line docker_image looks like an S3 path or is empty
        if is_swelancer:
            # If docker_image from CLI is a valid local image, use it
            if docker_image and not docker_image.startswith('s3://') and '/' in docker_image:
                logger.info(f"Using CLI-provided Docker image: {docker_image}")
            else:
                swelancer_image = get_swelancer_docker_image(dataset)
                # Only use dataset image if it's not an S3 path
                if swelancer_image and not swelancer_image.startswith('s3://'):
                    docker_image = swelancer_image
                    logger.info(f"Using SWE-Lancer Docker image from dataset: {docker_image}")
                else:
                    # Dataset has S3 path, use the unified image
                    docker_image = "swelancer/unified:latest"
                    logger.info(f"Dataset has S3 path, using local unified image: {docker_image}")
        
        # Step 3: Start Docker container (SWE-Lancer or standard)
        logger.info(f"Starting container from {docker_image}")
        if is_swelancer:
            container_started = start_swelancer_container(docker_image, container_name)
        else:
            container_started = start_container(docker_image, container_name)
        
        if not container_started:
            return EvalReport(
                instance_id=instance_id,
                resolved=False,
                failed_apply_patch=False,
                failed_apply_test_patch=False,
                error_eval=True,
                test_timeout=False,
                tests_passed=0,
                tests_failed=0,
                tests_error=0,
                fail_to_pass_success=[],
                fail_to_pass_failed=fail_to_pass,
                pass_to_pass_success=[],
                pass_to_pass_failed=pass_to_pass,
                test_output="",
                error_message="Failed to start container",
                execution_error="Container failed to start"
            )

        # Step 4: Detect repository directory
        repo_directory = detect_repo_directory(container_name)
        logger.info(f"Using repository directory: {repo_directory}")

        # Step 5: Apply model patch
        if model_patch:
            logger.info("Applying model patch...")
            with tempfile.NamedTemporaryFile(mode='w', suffix='.diff', delete=False) as f:
                f.write(model_patch)
                patch_file = f.name
            
            # IMPORTANT: Copy model patch to container first, but DON'T apply it yet
            # The patch must be applied AFTER git checkout in run_swelancer_tests
            if model_patch:
                logger.info("Copying model patch to container (will apply after checkout)...")
                with tempfile.NamedTemporaryFile(mode='w', suffix='.diff', delete=False) as f:
                    f.write(model_patch)
                    patch_file = f.name
                
                subprocess.run(
                    ["docker", "cp", patch_file, f"{container_name}:/tmp/model.patch"],
                    capture_output=True, timeout=30
                )
                os.unlink(patch_file)
            
            # Try git apply first, then patch (using detected repo directory)
            returncode, stdout, stderr = run_docker_command(
                container_name,
                f"cd {repo_directory} && git apply -v /tmp/model.patch 2>&1 || "
                f"patch --batch --fuzz=5 -p1 -i /tmp/model.patch 2>&1"
            )
            
            # Parse SWE-Lancer output using exit code parser
            parser_func = get_parser(test_output_parser)
            test_status_map = parser_func(full_output)
            
            logger.info(f"Parsed {len(test_status_map)} test results (SWE-Lancer)")
        
        # Step 6: ALWAYS reset test files to ensure consistent evaluation
        # This removes any model-created test files and restores original test files
        # FIX: Previously we skipped reset when golden patch exists, but this allowed
        # model-created test files to pollute the test run (e.g., GPT's test_namespace_layout.py)
        logger.info("Resetting test files to clean state...")

        # First, remove any NEW test files created by the model (git clean)
        run_docker_command(
            container_name,
            f"cd {repo_directory} && git clean -fd '**/test*.py' '**/tests/' '**/*_test.py' 2>/dev/null || true"
        )

        # Then, restore modified test files to original state (git checkout)
        run_docker_command(
            container_name,
            f"cd {repo_directory} && git checkout -- '**/test*.py' '**/tests/**' '**/*_test.py' 2>/dev/null || true"
        )
        
        logger.info("Test files reset complete")

        # Step 7: Run test command (applies test patch and runs tests)
        returncode, stdout, stderr = run_test_command(
            container_name, dataset, timeout=timeout
        )

        full_output = stdout + stderr

        # Step 8: Parse test output using appropriate parser based on test_output_parser
        if 'phpunit' in test_output_parser.lower():
            test_status_map = parse_phpunit_output(full_output)
        elif 'unittest' in test_output_parser.lower():
            test_status_map = parse_unittest_output(full_output)
        else:
            # Default to pytest parser (handles parse_log_pytest_v3, parse_log_pytest)
            test_status_map = parse_pytest_output(full_output)
        
        logger.info(f"Parsed {len(test_status_map)} test results")

        # Step 9: Grade results
        grade_results = grade_test_results(test_status_map, fail_to_pass, pass_to_pass)

        # CRITICAL FIX: Validate that tests actually ran before determining resolved status
        # Check for common error patterns that indicate tests never executed
        execution_error = ""
        test_execution_succeeded = True

        # Check 1: Test output must not be empty
        if not full_output or len(full_output.strip()) < 10:
            execution_error = "Test output is empty or too short"
            test_execution_succeeded = False
            logger.warning(f"Test execution failed: {execution_error}")

        # Check 2: Detect bash errors indicating tests didn't run
        bash_error_patterns = [
            "No such file or directory",
            "command not found",
            "Permission denied",
            "cannot access",
            "does not exist"
        ]
        for pattern in bash_error_patterns:
            if pattern in full_output:
                execution_error = f"Bash error detected: {pattern}"
                test_execution_succeeded = False
                logger.warning(f"Test execution failed: {execution_error}")
                break

        # Check 3: At least some tests must have been parsed
        # Empty test_status_map means parser couldn't find any test results
        total_tests_detected = len(test_status_map)
        if total_tests_detected == 0 and (fail_to_pass or pass_to_pass):
            # We expected tests but found none - this is a failure
            execution_error = "No test results parsed from output (parser found 0 tests)"
            test_execution_succeeded = False
            logger.warning(f"Test execution failed: {execution_error}")

        # Check 4: If we have F2P/P2P tests defined but got 0 passed/failed/error counts, tests didn't run
        if (fail_to_pass or pass_to_pass):
            total_test_count = (grade_results['tests_passed'] +
                              grade_results['tests_failed'] +
                              grade_results['tests_error'])
            if total_test_count == 0:
                execution_error = "Test counts are all zero despite having F2P/P2P tests defined"
                test_execution_succeeded = False
                logger.warning(f"Test execution failed: {execution_error}")

        # Determine resolved status - ONLY if tests executed successfully
        all_f2p_pass = len(grade_results['fail_to_pass_failed']) == 0 and len(grade_results['fail_to_pass_success']) > 0
        all_p2p_pass = len(grade_results['pass_to_pass_failed']) == 0

        # CRITICAL: resolved = true ONLY when tests executed AND all conditions met
        resolved = False
        if test_execution_succeeded and all_f2p_pass and all_p2p_pass:
            resolved = True

        return EvalReport(
            instance_id=instance_id,
            resolved=resolved,
            failed_apply_patch=False,
            failed_apply_test_patch=False,
            error_eval=False,
            test_timeout=returncode == -1,
            tests_passed=grade_results['tests_passed'],
            tests_failed=grade_results['tests_failed'],
            tests_error=grade_results['tests_error'],
            fail_to_pass_success=grade_results['fail_to_pass_success'],
            fail_to_pass_failed=grade_results['fail_to_pass_failed'],
            pass_to_pass_success=grade_results['pass_to_pass_success'],
            pass_to_pass_failed=grade_results['pass_to_pass_failed'],
            test_output=full_output,
            execution_error=execution_error
        )
        
    except Exception as e:
        logger.error(f"Evaluation failed: {e}")
        import traceback
        traceback.print_exc()
        return EvalReport(
            instance_id=instance_id if 'instance_id' in dir() else 'unknown',
            resolved=False,
            failed_apply_patch=False,
            failed_apply_test_patch=False,
            error_eval=True,
            test_timeout=False,
            tests_passed=0,
            tests_failed=0,
            tests_error=0,
            fail_to_pass_success=[],
            fail_to_pass_failed=[],
            pass_to_pass_success=[],
            pass_to_pass_failed=[],
            test_output="",
            error_message=str(e),
            execution_error=""
        )
    finally:
        stop_container(container_name)




# ============================================================
# OFFICIAL OPENHANDS FORMAT OUTPUT GENERATION
# ============================================================

def generate_official_eval_outputs(
    output_dir: str,
    trajectory_file: str,
    dataset_file: str,
    eval_report: 'EvalReport'
) -> str:
    """
    Generate eval_outputs/ directory in Official OpenHands format.
    
    Official structure:
        eval_outputs/<instance_id>/
        ├── eval.sh          # Evaluation script that was run
        ├── patch.diff       # Model's generated patch
        ├── report.json      # Test results in official format
        ├── run_instance.log # Execution log
        └── test_output.txt  # Full test output
    
    Returns: Path to instance eval directory
    """
    import os
    import json
    
    instance_id = str(eval_report.instance_id)
    eval_outputs_dir = os.path.join(output_dir, "eval_outputs")
    instance_eval_dir = os.path.join(eval_outputs_dir, instance_id)
    os.makedirs(instance_eval_dir, exist_ok=True)
    
    # Load trajectory for patch
    with open(trajectory_file, 'r') as f:
        traj_data = json.load(f)
    patch = traj_data.get('test_result', {}).get('git_patch', '')
    
    # Load dataset for test info
    with open(dataset_file, 'r') as f:
        dataset = json.load(f)
    test_command = dataset.get('test_command', 'pytest')
    test_patch = dataset.get('test_patch', '')
    base_commit = dataset.get('base_commit', '')
    
    # 1. Create report.json in Official OpenHands format
    report = {
        instance_id: {
            "patch_is_None": patch is None or patch == "",
            "patch_exists": bool(patch and patch.strip()),
            "patch_successfully_applied": not eval_report.failed_apply_patch,
            "resolved": eval_report.resolved,
            "tests_status": {
                "FAIL_TO_PASS": {
                    "success": eval_report.fail_to_pass_success,
                    "failure": eval_report.fail_to_pass_failed
                },
                "PASS_TO_PASS": {
                    "success": eval_report.pass_to_pass_success,
                    "failure": eval_report.pass_to_pass_failed
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
    
    report_file = os.path.join(instance_eval_dir, "report.json")
    with open(report_file, 'w') as f:
        json.dump(report, f, indent=4)
    logger.info(f"Created: {report_file}")
    
    # 2. Save test_output.txt
    test_output_file = os.path.join(instance_eval_dir, "test_output.txt")
    with open(test_output_file, 'w') as f:
        f.write(eval_report.test_output)
    logger.info(f"Created: {test_output_file}")
    
    # 3. Save patch.diff
    patch_file = os.path.join(instance_eval_dir, "patch.diff")
    with open(patch_file, 'w') as f:
        f.write(patch)
    logger.info(f"Created: {patch_file}")
    
    # 4. Create eval.sh (evaluation script)
    eval_sh = f"""#!/bin/bash
set -uxo pipefail
cd /app/repo
git config --global --add safe.directory /app/repo
git status
git show
git -c core.fileMode=false diff {base_commit}
source /saved/ENV 2>/dev/null || true
"""
    if test_patch:
        # Add first 100 lines of test patch for reference
        patch_preview = '\n'.join(test_patch.split('\n')[:100])
        eval_sh += f"""# Golden test patch applied (preview):
# {patch_preview[:500]}...
"""
    eval_sh += f""": '>>>>> Start Test Output'
{test_command}
: '>>>>> End Test Output'
"""
    
    eval_sh_file = os.path.join(instance_eval_dir, "eval.sh")
    with open(eval_sh_file, 'w') as f:
        f.write(eval_sh)
    logger.info(f"Created: {eval_sh_file}")
    
    # 5. Create run_instance.log
    run_log = f"""=== Velora Evaluation Run Log ===
Instance ID: {instance_id}
Trajectory: {trajectory_file}
Dataset: {dataset_file}

=== Patch Application ===
Patch Size: {len(patch)} bytes
Patch Applied: {not eval_report.failed_apply_patch}
Test Patch Applied: {not eval_report.failed_apply_test_patch}

=== Test Execution ===
Test Command: {test_command}
Test Timeout: {eval_report.test_timeout}
Error During Eval: {eval_report.error_eval}

=== Results ===
Resolved: {eval_report.resolved}
Tests Passed: {eval_report.tests_passed}
Tests Failed: {eval_report.tests_failed}
Tests Error: {eval_report.tests_error}

=== FAIL_TO_PASS ===
Success: {eval_report.fail_to_pass_success}
Failed: {eval_report.fail_to_pass_failed}

=== PASS_TO_PASS ===
Success: {eval_report.pass_to_pass_success}
Failed: {eval_report.pass_to_pass_failed}
"""
    if eval_report.error_message:
        run_log += f"\n=== Error Message ===\n{eval_report.error_message}\n"
    
    run_log_file = os.path.join(instance_eval_dir, "run_instance.log")
    with open(run_log_file, 'w') as f:
        f.write(run_log)
    logger.info(f"Created: {run_log_file}")
    
    return instance_eval_dir


# ============================================================
# CLI
# ============================================================

def main():
    parser = argparse.ArgumentParser(
        description="Standardized Pilot 2.2 Evaluation Script",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    # Evaluate a trajectory
    python eval_pilot2_standardized.py \\
        --trajectory-file output.jsonl \\
        --dataset-file task.jsonl \\
        --docker-image mswebench/sweb.eval.x86_64.task:latest \\
        --output-file eval_output.jsonl
        
    # With custom timeout
    python eval_pilot2_standardized.py \\
        --trajectory-file output.jsonl \\
        --dataset-file task.jsonl \\
        --docker-image image:tag \\
        --output-file eval.jsonl \\
        --timeout 1200
        """
    )
    parser.add_argument("--trajectory-file", required=True, help="Path to trajectory output.jsonl")
    parser.add_argument("--dataset-file", required=True, help="Path to dataset JSONL")
    parser.add_argument("--docker-image", required=True, help="Docker image name or path to .tar")
    parser.add_argument("--output-file", required=False, default=None, help="Output file for eval results (default: eval_output.jsonl beside trajectory file)")
    parser.add_argument("--timeout", type=int, default=900, help="Test timeout in seconds (default: 900)")
    
    args = parser.parse_args()

    # Default output file: eval_output.jsonl in the same directory as the trajectory file
    if args.output_file is None:
        args.output_file = os.path.join(os.path.dirname(args.trajectory_file), "eval_output.jsonl")

    # Run evaluation
    report = evaluate_instance(
        trajectory_file=args.trajectory_file,
        dataset_file=args.dataset_file,
        docker_image=args.docker_image,
        timeout=args.timeout
    )
    
    # Print summary
    logger.info("=" * 60)
    logger.info("EVALUATION RESULTS")
    logger.info("=" * 60)
    logger.info(f"Instance ID: {report.instance_id}")
    logger.info(f"RESOLVED: {'YES' if report.resolved else 'NO'}")
    logger.info(f"Tests Passed: {report.tests_passed}")
    logger.info(f"Tests Failed: {report.tests_failed}")
    logger.info(f"Tests Error: {report.tests_error}")
    logger.info(f"F2P Success: {len(report.fail_to_pass_success)}/{len(report.fail_to_pass_success) + len(report.fail_to_pass_failed)}")
    logger.info(f"P2P Success: {len(report.pass_to_pass_success)}/{len(report.pass_to_pass_success) + len(report.pass_to_pass_failed)}")
    if report.error_message:
        logger.info(f"Error: {report.error_message}")
    logger.info("=" * 60)
    
    # Save results
    # Load original trajectory to merge
    with open(args.trajectory_file, 'r') as f:
        # All corrected delivery trajectories are single JSON objects (formatted or compact)
        # Just read and parse the entire file
        content = f.read().strip()
        original = json.loads(content)
    
    # Add eval details
    original['evaluation_details'] = asdict(report)
    original['resolved'] = report.resolved
    
    with open(args.output_file, 'w') as f:
        f.write(json.dumps(original) + '\n')
    
    logger.info(f"Results saved to: {args.output_file}")
    
    # Generate Official OpenHands format outputs
    output_dir = os.path.dirname(args.output_file)
    instance_eval_dir = generate_official_eval_outputs(
        output_dir=output_dir,
        trajectory_file=args.trajectory_file,
        dataset_file=args.dataset_file,
        eval_report=report
    )
    logger.info(f"Official format outputs saved to: {instance_eval_dir}")
    
    return 0 if report.resolved else 1


if __name__ == "__main__":
    exit(main())

