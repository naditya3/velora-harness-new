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


# Parser registry mapping parser names to functions
PARSER_REGISTRY: Dict[str, Callable] = {
    "python/parse_log_pytest_v3": parse_log_pytest_v3,
    "python/parse_log_pytest": parse_log_pytest_v3,  # Alias
    "python/parse_log_unittest": parse_log_unittest,
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


def start_container(docker_image: str, container_name: str) -> bool:
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
             "--entrypoint", "/bin/bash", docker_image, "-c", "sleep 3600"],
            capture_output=True,
            text=True,
            timeout=120
        )
        return result.returncode == 0
    except Exception as e:
        logger.error(f"Failed to start container: {e}")
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
# EVAL SCRIPT GENERATION (following test_spec.py:make_eval_test_spec)
# ============================================================

def run_test_command(container_name: str, instance: Dict[str, Any], timeout: int = 900) -> tuple:
    """
    Run the test command from the dataset, following client's test_spec.py flow.
    
    Returns: (returncode, stdout, stderr)
    """
    repo_directory = "/app/repo"
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
        
        returncode, stdout, stderr = run_docker_command(
            container_name,
            f"cd {repo_directory} && git apply -v /tmp/test.patch 2>&1 || "
            f"patch --batch --fuzz=5 -p1 -i /tmp/test.patch 2>&1 || true"
        )
        logger.info(f"Test patch {i+1} apply result: {returncode}")
    
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
    
    # Build a clean command: source ENV, unset proxies, then run tests
    full_command = (
        f"source /saved/ENV 2>/dev/null || source /saved/*/ENV 2>/dev/null || true; "
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
    for test in fail_to_pass:
        matched = False
        for result_test, status in test_status_map.items():
            # Check exact match or substring match
            if test == result_test or test in result_test or result_test in test:
                if status == TestStatus.PASSED:
                    results['fail_to_pass_success'].append(test)
                else:
                    results['fail_to_pass_failed'].append(test)
                matched = True
                break
        
        if not matched:
            logger.warning(f"F2P test not found in output: {test}")
            results['fail_to_pass_failed'].append(test)
    
    # Grade P2P tests (should still pass)
    # XFAIL and XPASS are acceptable for P2P (not regressions)
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
            # P2P test not found - might be skipped, count as failed for safety
            logger.warning(f"P2P test not found in output: {test}")
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
        
        # Step 3: Start Docker container
        logger.info(f"Starting container from {docker_image}")
        if not start_container(docker_image, container_name):
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
                error_message="Failed to start container"
            )
        
        # Step 4: Apply model patch
        if model_patch:
            logger.info("Applying model patch...")
            with tempfile.NamedTemporaryFile(mode='w', suffix='.diff', delete=False) as f:
                f.write(model_patch)
                patch_file = f.name
            
            subprocess.run(
                ["docker", "cp", patch_file, f"{container_name}:/tmp/model.patch"],
                capture_output=True, timeout=30
            )
            os.unlink(patch_file)
            
            # Try git apply first, then patch
            returncode, stdout, stderr = run_docker_command(
                container_name,
                "cd /app/repo && git apply -v /tmp/model.patch 2>&1 || "
                "patch --batch --fuzz=5 -p1 -i /tmp/model.patch 2>&1"
            )
            
            if returncode != 0 and "FAILED" in stdout:
                logger.warning("Patch application may have failed")
        
        # Step 5: ALWAYS reset test files to ensure consistent evaluation
        # This removes any model-created test files and restores original test files
        # FIX: Previously we skipped reset when golden patch exists, but this allowed
        # model-created test files to pollute the test run (e.g., GPT's test_namespace_layout.py)
        logger.info("Resetting test files to clean state...")
        
        # First, remove any NEW test files created by the model (git clean)
        run_docker_command(
            container_name,
            "cd /app/repo && git clean -fd '**/test*.py' '**/tests/' '**/*_test.py' 2>/dev/null || true"
        )
        
        # Then, restore modified test files to original state (git checkout)
        run_docker_command(
            container_name,
            "cd /app/repo && git checkout -- '**/test*.py' '**/tests/**' '**/*_test.py' 2>/dev/null || true"
        )
        
        logger.info("Test files reset complete")
        
        # Step 6: Run test command (applies test patch and runs tests)
        returncode, stdout, stderr = run_test_command(
            container_name, dataset, timeout=timeout
        )
        
        full_output = stdout + stderr
        
        # Step 7: Parse test output using appropriate parser based on test_output_parser
        if 'unittest' in test_output_parser.lower():
            test_status_map = parse_unittest_output(full_output)
        else:
            # Default to pytest parser (handles parse_log_pytest_v3, parse_log_pytest)
            test_status_map = parse_pytest_output(full_output)
        
        logger.info(f"Parsed {len(test_status_map)} test results")
        
        # Step 8: Grade results
        grade_results = grade_test_results(test_status_map, fail_to_pass, pass_to_pass)
        
        # Determine resolved status
        all_f2p_pass = len(grade_results['fail_to_pass_failed']) == 0 and len(grade_results['fail_to_pass_success']) > 0
        all_p2p_pass = len(grade_results['pass_to_pass_failed']) == 0
        resolved = all_f2p_pass and all_p2p_pass
        
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
            test_output=full_output[:50000]  # Limit output size
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
            error_message=str(e)
        )
    finally:
        stop_container(container_name)


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
    parser.add_argument("--output-file", required=True, help="Output file for eval results")
    parser.add_argument("--timeout", type=int, default=900, help="Test timeout in seconds (default: 900)")
    
    args = parser.parse_args()
    
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
    original['pilot2_eval_details'] = asdict(report)
    original['resolved'] = report.resolved
    
    with open(args.output_file, 'w') as f:
        f.write(json.dumps(original) + '\n')
    
    logger.info(f"Results saved to: {args.output_file}")
    
    return 0 if report.resolved else 1


if __name__ == "__main__":
    exit(main())

