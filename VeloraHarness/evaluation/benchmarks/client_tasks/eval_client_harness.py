#!/usr/bin/env python3
"""
Evaluation Script for Client's Repomate Harness

This script evaluates OpenHands trajectory outputs using the client's requirements:
- Working directory: /app/repo (literal path, not placeholder)
- Environment setup: source /saved/ENV || source /saved/*/ENV
- Test command: from CSV test_command field
- Log parser: from CSV test_output_parser field (using client's log_parsers.py)

Usage:
    python eval_client_harness.py \
        --trajectory-output /path/to/output.jsonl \
        --dataset /path/to/dataset.jsonl \
        --output-dir /path/to/eval_output
"""

import argparse
import json
import logging
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


# ============================================================================
# Test Status Enum (matching client's constants)
# ============================================================================
class TestStatus(Enum):
    """Test status values matching client's TestStatus enum."""
    PASSED = "PASSED"
    FAILED = "FAILED"
    ERROR = "ERROR"
    SKIPPED = "SKIPPED"
    XFAIL = "XFAIL"  # Expected failure
    XPASS = "XPASS"  # Unexpected pass


# ============================================================================
# Log Parsers (adapted from client's log_parsers.py)
# ============================================================================
def parse_log_pytest(log: str, f2p_tests: List[str], p2p_tests: List[str]) -> Dict[str, str]:
    """Parser for test logs generated with PyTest framework"""
    test_status_map = {}
    for line in log.split("\n"):
        if any(line.startswith(x.value) for x in TestStatus):
            if line.startswith(TestStatus.FAILED.value):
                line = line.replace(" - ", " ")
            test_case = line.split()
            if len(test_case) <= 1:
                continue
            test_status_map[test_case[1]] = TestStatus(test_case[0]).value
    return test_status_map


def parse_log_pytest_v2(log: str, f2p_tests: List[str], p2p_tests: List[str]) -> Dict[str, str]:
    """Parser for pytest with -rA output format"""
    test_status_map = {}
    
    # Match lines like: PASSED test_file.py::test_name
    # or: FAILED test_file.py::test_name - AssertionError
    pattern = re.compile(r'^(PASSED|FAILED|ERROR|SKIPPED|XFAIL|XPASS)\s+(\S+)')
    
    for line in log.split("\n"):
        match = pattern.match(line.strip())
        if match:
            status, test_name = match.groups()
            # Clean up test name (remove " - " and error message if present)
            test_name = test_name.split(" - ")[0].strip()
            test_status_map[test_name] = status
    
    return test_status_map


def parse_log_pytest_v3(log: str, f2p_tests: List[str], p2p_tests: List[str]) -> Dict[str, str]:
    """Parser for pytest v3 output format (most common)"""
    test_status_map = {}
    
    # Parse short test summary section
    in_summary = False
    for line in log.split("\n"):
        if "short test summary" in line.lower() or "= FAILURES =" in line:
            in_summary = True
            continue
        
        if in_summary:
            # Match status lines
            for status in TestStatus:
                if line.strip().startswith(status.value):
                    parts = line.strip().split(None, 1)
                    if len(parts) >= 2:
                        test_name = parts[1].split(" - ")[0].strip()
                        test_status_map[test_name] = status.value
                    break
    
    # Also check for inline status (test_name PASSED/FAILED)
    pattern = re.compile(r'^(\S+)\s+(PASSED|FAILED|ERROR|SKIPPED|XFAIL|XPASS)')
    for line in log.split("\n"):
        match = pattern.match(line.strip())
        if match:
            test_name, status = match.groups()
            if test_name not in test_status_map:
                test_status_map[test_name] = status
    
    return test_status_map


def parse_log_unittest(log: str, f2p_tests: List[str], p2p_tests: List[str]) -> Dict[str, str]:
    """
    Parser for unittest output format - aligned with client's implementation.
    Handles multi-line test output and various unittest formats.
    """
    test_status_map = {}
    lines = log.split("\n")
    
    line_num = 0
    while line_num < len(lines):
        line = lines[line_num].strip()
        
        # Handle ERROR: and FAILED: lines (summary section)
        line_starts_with_error = line.startswith("ERROR:")
        line_starts_with_failed = line.startswith("FAILED:")
        
        if line_starts_with_error or line_starts_with_failed:
            parts = line.split()
            if len(parts) >= 2:
                test_name = parts[1]
                if "(" in test_name:
                    if line_starts_with_error:
                        test_name = test_name.split("(")[0]
                    elif line_starts_with_failed:
                        class_name = test_name.split("(")[1].split(")")[0]
                        base_test_name = test_name.split("(")[0]
                        test_name = f"{class_name}.{base_test_name}"
                if line_starts_with_error:
                    test_status_map[test_name] = TestStatus.ERROR.value
                elif line_starts_with_failed:
                    test_status_map[test_name] = TestStatus.FAILED.value
        
        # Handle lines starting with test_ (actual test execution lines)
        elif line.startswith("test_"):
            test_name = line.split()[0] if line.split() else ""
            
            if test_name.startswith("test_"):
                class_name = ""
                if "(" in line and ")" in line:
                    paren_content = line.split("(")[1].split(")")[0]
                    class_name = paren_content
                
                # Look ahead to gather multi-line test output
                test_content = line
                lookahead_line_num = line_num + 1
                
                stop_prefixes = (
                    "test_",
                    "======================================================================",
                    "----------------------------------------------------------------------",
                )
                while lookahead_line_num < len(lines):
                    current_line = lines[lookahead_line_num].strip()
                    if any(current_line.startswith(prefix) for prefix in stop_prefixes):
                        break
                    test_content += " " + current_line
                    lookahead_line_num += 1
                
                full_test_name = f"{class_name}.{test_name}" if class_name else test_name
                
                if " ok" in test_content or test_content.endswith("ok"):
                    test_status_map[full_test_name] = TestStatus.PASSED.value
                elif "FAIL:" in test_content or test_content.endswith("FAIL"):
                    test_status_map[full_test_name] = TestStatus.FAILED.value
                elif "ERROR:" in test_content or test_content.endswith("ERROR"):
                    test_status_map[test_name] = TestStatus.ERROR.value
                elif "skipped" in test_content:
                    test_status_map[full_test_name] = TestStatus.SKIPPED.value
                else:
                    # Check if multi-line result ends with ok
                    remaining_lines = lines[line_num:lookahead_line_num]
                    combined_content = " ".join(remaining_lines)
                    if combined_content.rstrip().endswith(" ok") or combined_content.rstrip().endswith("\nok"):
                        test_status_map[full_test_name] = TestStatus.PASSED.value
                
                line_num = lookahead_line_num - 1
        
        line_num += 1
    
    return test_status_map


def parse_log_tox(log: str, f2p_tests: List[str], p2p_tests: List[str]) -> Dict[str, str]:
    """Parser for tox output (usually wraps pytest)"""
    # Tox usually runs pytest, so we can use pytest parser
    return parse_log_pytest_v3(log, f2p_tests, p2p_tests)


def parse_log_swelancer_exitcode(log: str, f2p_tests: List[str], p2p_tests: List[str]) -> Dict[str, str]:
    """
    Parser for SWE-Lancer that uses pytest exit code for grading.
    
    SWE-Lancer grading is based on pytest exit code:
    - Exit code 0 = PASS
    - Exit code 1 = FAIL
    - Exit code >= 2 = ERROR
    """
    test_status_map = {}
    
    # Look for exit code patterns
    exit_code = None
    
    # Pattern 1: pytest_exit_code
    match = re.search(r'pytest_exit_code[:\s=]+(\d+)', log, re.IGNORECASE)
    if match:
        exit_code = int(match.group(1))
    
    # Pattern 2: Exit code at end of output
    if exit_code is None:
        match = re.search(r'exit\s+code[:\s]+(\d+)', log, re.IGNORECASE)
        if match:
            exit_code = int(match.group(1))
    
    # Find test names in log or use provided f2p_tests
    test_names = f2p_tests if f2p_tests else ['test_expensify_0000']
    
    # Grade based on exit code
    if exit_code is not None:
        if exit_code == 0:
            for name in test_names:
                test_name = name.split("::")[-1] if "::" in name else name
                test_status_map[test_name] = TestStatus.PASSED.value
        elif exit_code == 1:
            for name in test_names:
                test_name = name.split("::")[-1] if "::" in name else name
                test_status_map[test_name] = TestStatus.FAILED.value
        else:
            for name in test_names:
                test_name = name.split("::")[-1] if "::" in name else name
                test_status_map[test_name] = TestStatus.ERROR.value
    else:
        # Fallback to checking for passed/failed summary
        if re.search(r'\d+\s+passed', log):
            for name in test_names:
                test_name = name.split("::")[-1] if "::" in name else name
                test_status_map[test_name] = TestStatus.PASSED.value
        elif re.search(r'\d+\s+failed', log):
            for name in test_names:
                test_name = name.split("::")[-1] if "::" in name else name
                test_status_map[test_name] = TestStatus.FAILED.value
    
    return test_status_map


def parse_log_playwright(log: str, f2p_tests: List[str], p2p_tests: List[str]) -> Dict[str, str]:
    """Parser for SWE-Lancer Playwright tests run via pytest."""
    # Playwright tests in SWE-Lancer are graded via exit code
    return parse_log_swelancer_exitcode(log, f2p_tests, p2p_tests)


# Parser registry
PARSER_REGISTRY = {
    "python/parse_log_pytest": parse_log_pytest,
    "python/parse_log_pytest_v2": parse_log_pytest_v2,
    "python/parse_log_pytest_v3": parse_log_pytest_v3,
    "python/parse_log_unittest": parse_log_unittest,
    "python/parse_log_tox": parse_log_tox,
    # SWE-Lancer parsers
    "javascript/parse_log_playwright": parse_log_playwright,
    "swelancer/parse_log_playwright": parse_log_playwright,
    "swelancer/parse_log_exitcode": parse_log_swelancer_exitcode,
}


def get_parser(parser_name: str):
    """Get the appropriate parser function"""
    if parser_name in PARSER_REGISTRY:
        return PARSER_REGISTRY[parser_name]
    
    # Default to pytest_v3
    logger.warning(f"Unknown parser '{parser_name}', defaulting to pytest_v3")
    return parse_log_pytest_v3


# ============================================================================
# Docker Execution Functions
# ============================================================================
def run_in_container(
    image: str,
    commands: List[str],
    timeout: int = 600,
    workdir: str = "/app/repo"
) -> Tuple[int, str, str]:
    """
    Run commands in a Docker container.
    
    Returns: (return_code, stdout, stderr)
    """
    # Join commands with &&
    full_command = " && ".join(commands)
    
    docker_cmd = [
        "docker", "run",
        "--rm",
        "--network", "none",  # No network access during testing
        "--workdir", workdir,
        "--entrypoint", "",
        image,
        "/bin/bash", "-c", full_command
    ]
    
    logger.info(f"Running in container: {' '.join(docker_cmd[:6])}...")
    
    try:
        result = subprocess.run(
            docker_cmd,
            capture_output=True,
            text=True,
            timeout=timeout
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        logger.error(f"Command timed out after {timeout}s")
        return -1, "", f"Timeout after {timeout}s"
    except Exception as e:
        logger.error(f"Docker execution failed: {e}")
        return -1, "", str(e)


def apply_patch_and_test(
    image: str,
    patch: str,
    test_command: str,
    base_commit: str,
    test_patch: str = "",
    timeout: int = 600
) -> Tuple[int, str, str]:
    """
    Apply the patch and run tests in the container.
    
    Client's flow:
    1. cd /app/repo
    2. source /saved/ENV || source /saved/*/ENV
    3. git reset --hard {base_commit}
    4. Apply model patch
    5. Apply test patch (if any)
    6. Run test command
    
    Uses base64 encoding to safely transfer patches (avoids heredoc issues).
    """
    import base64
    
    # Build the script to run inside container
    script_lines = [
        "#!/bin/bash",
        "set -e",
        "cd /app/repo",
        "export HOME=/root",
        "source /saved/pytest/ENV 2>/dev/null || source /saved/*/ENV 2>/dev/null || true",
        "git config --global --add safe.directory /app/repo",
    ]
    
    # Reset to base commit if provided
    if base_commit:
        script_lines.append(f"git reset --hard {base_commit}")
    
    # Apply model patch using base64 decoding
    if patch and patch.strip():
        patch_b64 = base64.b64encode(patch.encode()).decode()
        script_lines.extend([
            f"echo '{patch_b64}' | base64 -d > /tmp/model.patch",
            "echo '=== Applying model patch ==='",
            "git apply --verbose /tmp/model.patch 2>&1 || git apply --verbose --reject /tmp/model.patch 2>&1 || echo 'Patch apply failed'",
        ])
    
    # Apply test patch using base64 decoding
    if test_patch and test_patch.strip():
        # Handle test_patch which might be a JSON array of patches
        patches_to_apply = []
        if test_patch.startswith('['):
            try:
                patches = json.loads(test_patch)
                if isinstance(patches, list):
                    patches_to_apply = patches
            except:
                patches_to_apply = [test_patch]
        else:
            patches_to_apply = [test_patch]
        
        # Apply each patch separately
        script_lines.append("echo '=== Applying test patches ==='")
        for i, single_patch in enumerate(patches_to_apply):
            if single_patch and single_patch.strip():
                # Ensure patch ends with newline (required by git apply)
                if not single_patch.endswith('\n'):
                    single_patch = single_patch + '\n'
                patch_b64 = base64.b64encode(single_patch.encode()).decode()
                script_lines.extend([
                    f"echo '{patch_b64}' | base64 -d > /tmp/test_patch_{i}.patch",
                    f"git apply --verbose /tmp/test_patch_{i}.patch 2>&1 || echo 'Test patch {i} apply warning'",
                ])
    
    # Run the test command
    script_lines.extend([
        "echo '=== START TEST OUTPUT ==='",
        test_command,
        "EXIT_CODE=$?",
        "echo '=== END TEST OUTPUT ==='",
        "exit $EXIT_CODE",
    ])
    
    # Create the full script
    full_script = '\n'.join(script_lines)
    
    # Run the script in container
    docker_cmd = [
        "docker", "run",
        "--rm",
        "--network", "none",
        "--workdir", "/app/repo",
        "--entrypoint", "",
        image,
        "/bin/bash", "-c", full_script
    ]
    
    logger.info(f"Running in container: {image}")
    
    try:
        result = subprocess.run(
            docker_cmd,
            capture_output=True,
            text=True,
            timeout=timeout
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        logger.error(f"Command timed out after {timeout}s")
        return -1, "", f"Timeout after {timeout}s"
    except Exception as e:
        logger.error(f"Docker execution failed: {e}")
        return -1, "", str(e)


# ============================================================================
# Evaluation Logic
# ============================================================================
@dataclass
class EvalResult:
    """Evaluation result for a single instance"""
    instance_id: str
    resolved: bool
    f2p_status: Dict[str, str]  # fail_to_pass test results
    p2p_status: Dict[str, str]  # pass_to_pass test results
    f2p_pass_count: int
    f2p_total: int
    p2p_pass_count: int
    p2p_total: int
    patch_applied: bool
    test_output: str
    error_message: str = ""
    model_patch: str = ""  # For saving patch.diff
    eval_script: str = ""  # For saving eval.sh


def evaluate_instance(
    instance: Dict[str, Any],
    model_patch: str,
    docker_image: str,
    timeout: int = 600
) -> EvalResult:
    """
    Evaluate a single instance using client's harness requirements.
    """
    instance_id = instance.get("instance_id", "unknown")
    test_command = instance.get("test_command", "pytest --no-header -rA --tb=no")
    test_patch = instance.get("test_patch", "")
    base_commit = instance.get("base_commit", "")
    parser_name = instance.get("test_output_parser", "python/parse_log_pytest_v3")
    
    # Parse test lists
    f2p_tests = parse_test_list(instance.get("fail_to_pass_tests", ""))
    p2p_tests = parse_test_list(instance.get("pass_to_pass_tests", ""))
    
    logger.info(f"Evaluating {instance_id}")
    logger.info(f"  F2P tests: {len(f2p_tests)}, P2P tests: {len(p2p_tests)}")
    logger.info(f"  Parser: {parser_name}")
    logger.info(f"  Test command: {test_command[:80]}...")
    
    # Run evaluation in container
    returncode, stdout, stderr = apply_patch_and_test(
        image=docker_image,
        patch=model_patch,
        test_command=test_command,
        base_commit=base_commit,
        test_patch=test_patch,
        timeout=timeout
    )
    
    # Extract test output between markers
    full_output = stdout + "\n" + stderr
    test_output = extract_test_output(full_output)
    
    # Check if patch was applied successfully
    patch_applied = "Patch apply warning" not in full_output and returncode != -1
    
    # Parse test results
    parser = get_parser(parser_name)
    test_results = parser(test_output, f2p_tests, p2p_tests)
    
    # Categorize results - Only count tests that are explicitly in F2P or P2P lists
    f2p_status = {}
    p2p_status = {}
    uncategorized = {}
    
    for test_name, status in test_results.items():
        # Check if this test is in f2p list (use exact or suffix match)
        matched_f2p = False
        for f2p_test in f2p_tests:
            if test_name == f2p_test or test_name.endswith(f2p_test) or f2p_test in test_name:
                f2p_status[test_name] = status
                matched_f2p = True
                break
        
        if not matched_f2p:
            # Check if this test is in p2p list
            matched_p2p = False
            for p2p_test in p2p_tests:
                if test_name == p2p_test or test_name.endswith(p2p_test) or p2p_test in test_name:
                    p2p_status[test_name] = status
                    matched_p2p = True
                    break
            
            if not matched_p2p:
                # Test is not in either list - don't count it
                uncategorized[test_name] = status
    
    # Calculate pass counts - ONLY from tests that matched the explicit lists
    passing_statuses = {TestStatus.PASSED.value, TestStatus.XFAIL.value}
    f2p_pass = sum(1 for s in f2p_status.values() if s in passing_statuses)
    p2p_pass = sum(1 for s in p2p_status.values() if s in passing_statuses)
    
    # Determine if resolved (all F2P pass, all P2P pass)
    f2p_resolved = f2p_pass == len(f2p_tests) if f2p_tests else True
    p2p_resolved = p2p_pass == len(p2p_tests) if p2p_tests else True
    resolved = f2p_resolved and p2p_resolved and patch_applied
    
    return EvalResult(
        instance_id=instance_id,
        resolved=resolved,
        f2p_status=f2p_status,
        p2p_status=p2p_status,
        f2p_pass_count=f2p_pass,
        f2p_total=len(f2p_tests),
        p2p_pass_count=p2p_pass,
        p2p_total=len(p2p_tests),
        patch_applied=patch_applied,
        test_output=test_output,
        error_message="" if returncode != -1 else stderr,
        model_patch=model_patch,
        eval_script=""  # Will be set by caller if needed
    )


def extract_test_output(full_output: str) -> str:
    """Extract test output between START/END markers"""
    start_marker = "=== START TEST OUTPUT ==="
    end_marker = "=== END TEST OUTPUT ==="
    
    start_idx = full_output.find(start_marker)
    end_idx = full_output.find(end_marker)
    
    if start_idx != -1 and end_idx != -1:
        return full_output[start_idx + len(start_marker):end_idx].strip()
    
    # If markers not found, return everything after environment setup
    return full_output


def parse_test_list(test_str: str) -> List[str]:
    """Parse test list from CSV string format"""
    if not test_str:
        return []
    
    # Handle JSON array format
    if test_str.startswith("["):
        try:
            return json.loads(test_str)
        except json.JSONDecodeError:
            pass
    
    # Handle comma-separated format
    tests = [t.strip().strip('"').strip("'") for t in test_str.split(",")]
    return [t for t in tests if t]


# ============================================================================
# Main Evaluation Pipeline
# ============================================================================
def load_trajectory_output(output_path: str) -> List[Dict[str, Any]]:
    """Load trajectory outputs from JSONL file"""
    outputs = []
    with open(output_path, 'r') as f:
        for line in f:
            if line.strip():
                outputs.append(json.loads(line))
    return outputs


def load_dataset(dataset_path: str) -> Dict[str, Dict[str, Any]]:
    """Load dataset and index by instance_id"""
    instances = {}
    with open(dataset_path, 'r') as f:
        for line in f:
            if line.strip():
                instance = json.loads(line)
                instances[instance.get("instance_id")] = instance
    return instances


def get_docker_image_for_instance(instance: Dict[str, Any], instance_id: str) -> str:
    """
    Determine the Docker image for an instance.
    
    Priority:
    1. SWE-Lancer monolith mode (if USE_SWELANCER_MONOLITH env var is set)
    2. monolith_image field in instance (if PREFER_MONOLITH env var is set)
    3. task_specific_image field in instance
    4. image_storage_uri field in instance
    5. mswebench tagged image
    6. Construct from instance_id pattern
    """
    # Check for SWE-Lancer monolith mode
    if os.environ.get('USE_SWELANCER_MONOLITH', 'false').lower() == 'true':
        monolith_image = os.environ.get('SWELANCER_MONOLITH_IMAGE', 'swelancer/swelancer_x86_monolith:releasev1')
        logger.info(f"Using SWE-Lancer monolith image: {monolith_image}")
        return monolith_image
    
    # Check for monolith_image field (SWE-Lancer datasets)
    if os.environ.get('PREFER_MONOLITH', 'false').lower() == 'true':
        monolith_image = instance.get('monolith_image', '')
        if monolith_image:
            logger.info(f"Using monolith_image from dataset: {monolith_image}")
            return monolith_image
    
    # Check for task_specific_image field (SWE-Lancer datasets)
    task_image = instance.get('task_specific_image', '')
    if task_image:
        logger.info(f"Using task_specific_image from dataset: {task_image}")
        return task_image
    
    # Check for image_storage_uri in instance
    if "image_storage_uri" in instance and instance["image_storage_uri"]:
        uri = instance["image_storage_uri"]
        # Return the full URI - it should be available locally after docker load
        # Format: vmvm-registry.fbinfra.net/repomate_image_activ_pytest/repo_name:commit
        return uri
    
    # Try mswebench tagged format
    # Format: mswebench/owner_m_repo:pr-instance_id
    repo = instance.get("repo", "")
    if repo:
        repo_underscore = repo.replace("/", "_m_")
        return f"mswebench/{repo_underscore}:pr-{instance_id}"
    
    # Try to construct from instance_id
    # Format: owner_repo-instance_num or owner__repo-commit
    if "__" in instance_id:
        # SWE-bench style
        parts = instance_id.split("__")
        return f"swebench/sweb.eval.x86_64.{parts[0]}_{parts[1]}:latest"
    
    # Default - try to match loaded images
    return instance_id


def run_evaluation_pipeline(
    trajectory_path: str,
    dataset_path: str,
    output_dir: str,
    timeout: int = 600
) -> None:
    """
    Main evaluation pipeline.
    """
    os.makedirs(output_dir, exist_ok=True)
    
    # Load data
    logger.info(f"Loading trajectory output from {trajectory_path}")
    trajectories = load_trajectory_output(trajectory_path)
    
    logger.info(f"Loading dataset from {dataset_path}")
    dataset = load_dataset(dataset_path)
    
    logger.info(f"Loaded {len(trajectories)} trajectories, {len(dataset)} dataset instances")
    
    results = []
    
    for traj in trajectories:
        instance_id = traj.get("instance_id", "unknown")
        
        # Get the model's patch from trajectory
        model_patch = traj.get("test_result", {}).get("git_patch", "")
        if not model_patch:
            model_patch = traj.get("git_patch", "")
        
        # Get dataset instance
        instance = dataset.get(instance_id, {})
        if not instance:
            logger.warning(f"Instance {instance_id} not found in dataset, skipping")
            continue
        
        # Get Docker image
        docker_image = get_docker_image_for_instance(instance, instance_id)
        
        logger.info(f"\n{'='*60}")
        logger.info(f"Processing: {instance_id}")
        logger.info(f"Docker image: {docker_image}")
        logger.info(f"Patch size: {len(model_patch)} chars")
        
        try:
            result = evaluate_instance(
                instance=instance,
                model_patch=model_patch,
                docker_image=docker_image,
                timeout=timeout
            )
            # Add eval_script from instance for saving eval.sh
            result.eval_script = instance.get("test_command", "pytest --no-header -rA --tb=no")
            results.append(result)
            
            logger.info(f"Result: {'RESOLVED' if result.resolved else 'FAILED'}")
            logger.info(f"  F2P: {result.f2p_pass_count}/{result.f2p_total}")
            logger.info(f"  P2P: {result.p2p_pass_count}/{result.p2p_total}")
            
        except Exception as e:
            logger.error(f"Error evaluating {instance_id}: {e}")
            results.append(EvalResult(
                instance_id=instance_id,
                resolved=False,
                f2p_status={},
                p2p_status={},
                f2p_pass_count=0,
                f2p_total=0,
                p2p_pass_count=0,
                p2p_total=0,
                patch_applied=False,
                test_output="",
                error_message=str(e)
            ))
    
    # Save results
    save_results(results, output_dir)
    
    # Print summary
    print_summary(results)


def save_results(results: List[EvalResult], output_dir: str) -> None:
    """Save evaluation results in both custom and OpenHands format"""
    # Save detailed JSONL
    output_jsonl = os.path.join(output_dir, "eval_results.jsonl")
    with open(output_jsonl, 'w') as f:
        for r in results:
            f.write(json.dumps({
                "instance_id": r.instance_id,
                "resolved": r.resolved,
                "f2p_status": r.f2p_status,
                "p2p_status": r.p2p_status,
                "f2p_pass_count": r.f2p_pass_count,
                "f2p_total": r.f2p_total,
                "p2p_pass_count": r.p2p_pass_count,
                "p2p_total": r.p2p_total,
                "patch_applied": r.patch_applied,
                "error_message": r.error_message
            }) + "\n")
    
    # Save test outputs
    test_output_dir = os.path.join(output_dir, "test_outputs")
    os.makedirs(test_output_dir, exist_ok=True)
    for r in results:
        output_file = os.path.join(test_output_dir, f"{r.instance_id}.txt")
        with open(output_file, 'w') as f:
            f.write(r.test_output)
    
    # === Generate OpenHands-style report.json for each instance ===
    for r in results:
        instance_dir = os.path.join(output_dir, str(r.instance_id))
        os.makedirs(instance_dir, exist_ok=True)
        
        # Create OpenHands-compatible report.json
        report = {
            str(r.instance_id): {
                "patch_is_None": False,
                "patch_exists": True,
                "patch_successfully_applied": r.patch_applied,
                "resolved": r.resolved,
                "tests_status": {
                    "FAIL_TO_PASS": {
                        "success": [k for k, v in r.f2p_status.items() if v in ['PASSED', 'XFAIL']],
                        "failure": [k for k, v in r.f2p_status.items() if v not in ['PASSED', 'XFAIL']]
                    },
                    "PASS_TO_PASS": {
                        "success": [k for k, v in r.p2p_status.items() if v in ['PASSED', 'XFAIL']],
                        "failure": [k for k, v in r.p2p_status.items() if v not in ['PASSED', 'XFAIL']]
                    },
                    "FAIL_TO_FAIL": {"success": [], "failure": []},
                    "PASS_TO_FAIL": {"success": [], "failure": []}
                }
            }
        }
        
        # Write report.json
        with open(os.path.join(instance_dir, 'report.json'), 'w') as f:
            json.dump(report, f, indent=4)
        
        # Copy test output to instance directory
        with open(os.path.join(instance_dir, 'test_output.txt'), 'w') as f:
            f.write(r.test_output)
        
        # Save patch.diff (OpenHands format)
        if r.model_patch:
            with open(os.path.join(instance_dir, 'patch.diff'), 'w') as f:
                f.write(r.model_patch)
        
        # Save eval.sh (OpenHands format) - generate from instance data
        eval_script = f"""#!/bin/bash
set -uxo pipefail
cd /app/repo
source /saved/ENV || source /saved/*/ENV
git config --global --add safe.directory /app/repo
# Apply model patch
git apply -v /tmp/patch.diff
# Run tests
{r.eval_script if r.eval_script else "pytest --no-header -rA --tb=no"}
"""
        with open(os.path.join(instance_dir, 'eval.sh'), 'w') as f:
            f.write(eval_script)
        
        logger.info(f"Generated OpenHands-format report for {r.instance_id}")
    
    # Save summary JSON
    summary = {
        "total": len(results),
        "resolved": sum(1 for r in results if r.resolved),
        "failed": sum(1 for r in results if not r.resolved),
        "resolve_rate": sum(1 for r in results if r.resolved) / len(results) if results else 0
    }
    with open(os.path.join(output_dir, "summary.json"), 'w') as f:
        json.dump(summary, f, indent=2)
    
    logger.info(f"Results saved to {output_dir}")


def print_summary(results: List[EvalResult]) -> None:
    """Print evaluation summary"""
    total = len(results)
    resolved = sum(1 for r in results if r.resolved)
    
    print("\n" + "="*60)
    print("EVALUATION SUMMARY")
    print("="*60)
    print(f"Total instances: {total}")
    print(f"Resolved: {resolved}")
    print(f"Failed: {total - resolved}")
    print(f"Resolve rate: {resolved/total*100:.1f}%" if total > 0 else "N/A")
    print("="*60)
    
    # Show failed instances
    failed = [r for r in results if not r.resolved]
    if failed:
        print("\nFailed instances:")
        for r in failed[:10]:  # Show first 10
            print(f"  - {r.instance_id}: F2P={r.f2p_pass_count}/{r.f2p_total}, P2P={r.p2p_pass_count}/{r.p2p_total}")
            if r.error_message:
                print(f"    Error: {r.error_message[:80]}")


def main():
    parser = argparse.ArgumentParser(
        description="Evaluate OpenHands trajectories using client's Repomate harness"
    )
    parser.add_argument(
        "--trajectory-output", "-t",
        required=True,
        help="Path to trajectory output JSONL file"
    )
    parser.add_argument(
        "--dataset", "-d",
        required=True,
        help="Path to dataset JSONL file"
    )
    parser.add_argument(
        "--output-dir", "-o",
        required=True,
        help="Directory to save evaluation results"
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=600,
        help="Timeout for each evaluation in seconds (default: 600)"
    )
    
    args = parser.parse_args()
    
    run_evaluation_pipeline(
        trajectory_path=args.trajectory_output,
        dataset_path=args.dataset,
        output_dir=args.output_dir,
        timeout=args.timeout
    )


if __name__ == "__main__":
    main()

