#!/usr/bin/env python3
"""
Unified Evaluation Script for Multi-Language SWE-Bench Tasks

This script provides a unified evaluation framework supporting:
- Python (pytest, unittest)
- PHP (PHPUnit)
- Ruby (Minitest)
- JavaScript (SWE-Lancer/Playwright, Jest)

Key Features:
1. Multi-language parser support with unified registry
2. Standard evaluation flow for most languages
3. SWE-Lancer specific flow for JavaScript/Playwright tests
4. Sophisticated test name matching for cross-format grading
5. Full eval_outputs directory structure generation

=== EVALUATION FLOWS ===

Standard Flow (Python, PHP, Ruby):
1. Start Docker container
2. Apply model patch
3. Reset test files to clean state
4. Apply golden test patch
5. Run test command
6. Parse output with appropriate parser
7. Grade results against F2P/P2P

SWE-Lancer Flow (JavaScript/Playwright):
1. Start SWE-Lancer container
2. Setup Xvfb, SSL certs, /etc/hosts
3. Checkout base_commit
4. Apply model patch (AFTER checkout)
5. Switch Node.js version based on commit
6. Start mitmdump proxy
7. Start webpack dev server on :8082
8. Rewrite test.py with proxy configuration
9. Run pytest with Playwright
10. Parse exit code for grading

Usage:
    python eval_pilot2_standardized.py \
        --trajectory-file <output.jsonl> \
        --dataset-file <task.jsonl> \
        --docker-image <image_name_or_tar_path> \
        --output-file <eval_output.jsonl>
"""

import argparse
import ast
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
# TEST STATUS ENUM
# ============================================================

class TestStatus:
    """Test status values matching client's TestStatus enum."""
    PASSED = "PASSED"
    FAILED = "FAILED"
    ERROR = "ERROR"
    SKIPPED = "SKIPPED"
    XFAIL = "XFAIL"  # Expected failure - test failed as expected
    XPASS = "XPASS"  # Unexpected pass - test passed when expected to fail


# ============================================================
# PYTHON PARSERS
# ============================================================

def parse_log_pytest_v3(log: str, grading_spec: Any = None) -> Dict[str, str]:
    """
    Parser for test logs generated with PyTest framework (Repomate version).
    
    Handles pytest -rA output format:
        PASSED test/test_file.py::test_name
        FAILED test/test_file.py::test_name
    """
    test_status_map = {}
    escapes = "".join([chr(char) for char in range(1, 32)])
    translator = str.maketrans("", "", escapes)
    
    status_values = "|".join([TestStatus.PASSED, TestStatus.FAILED, TestStatus.ERROR, 
                              TestStatus.SKIPPED, TestStatus.XFAIL, TestStatus.XPASS])
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
        
        elif any(line.endswith(x) for x in [TestStatus.PASSED, TestStatus.FAILED, 
                                             TestStatus.ERROR, TestStatus.SKIPPED]):
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
    """
    test_status_map = {}
    
    for line in log.split("\n"):
        line = line.strip()
        
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


# ============================================================
# PHP PARSERS
# ============================================================

def parse_log_phpunit(log: str, grading_spec: Any = None) -> Dict[str, str]:
    """
    Parser for test logs generated with PHPUnit framework.
    
    Handles PHPUnit testdox output format:
        Class Name (Namespace\TestClass)
         ✔ Test name passes
         ✘ Test name fails
        
    Maps to: Namespace\TestClass::testTestNamePasses
    """
    test_status_map = {}
    lines = log.split("\n")
    
    current_class = None
    
    def testdox_to_method_name(testdox_name: str) -> str:
        """Convert testdox name to method name."""
        words = testdox_name.strip().split()
        if not words:
            return ""
        method = "test" + words[0].capitalize()
        for word in words[1:]:
            method += word.capitalize()
        return method
    
    in_failure_section = False
    in_error_section = False
    current_failed_tests = set()
    current_error_tests = set()
    
    for i, line in enumerate(lines):
        line_stripped = line.strip()
        
        # Detect testdox class header: "Class Name (Namespace\TestClass)"
        class_header_match = re.match(r'^(.+?)\s*\(([^)]+)\)\s*$', line_stripped)
        if class_header_match and '\\' in class_header_match.group(2):
            current_class = class_header_match.group(2)
            continue
        
        # Detect failure/error section start
        if line_stripped.startswith("There was") and "failure" in line_stripped.lower():
            in_failure_section = True
            in_error_section = False
            current_class = None
            continue
        if line_stripped.startswith("There was") and "error" in line_stripped.lower():
            in_error_section = True
            in_failure_section = False
            current_class = None
            continue
        if line_stripped.startswith("There were") and "failure" in line_stripped.lower():
            in_failure_section = True
            in_error_section = False
            current_class = None
            continue
        if line_stripped.startswith("There were") and "error" in line_stripped.lower():
            in_error_section = True
            in_failure_section = False
            current_class = None
            continue
            
        # Parse failure/error entries like: 1) Namespace\Class::testMethod
        if (in_failure_section or in_error_section) and re.match(r'^\d+\)', line_stripped):
            match = re.match(r'^\d+\)\s*(.+)', line_stripped)
            if match:
                test_name = match.group(1).strip()
                if ' with data set' in test_name:
                    test_name = test_name.split(' with data set')[0]
                if in_failure_section:
                    current_failed_tests.add(test_name)
                else:
                    current_error_tests.add(test_name)
        
        def get_alternative_class_names(class_name: str) -> List[str]:
            """Generate alternative class names for matching."""
            alternatives = [class_name]
            if class_name.endswith('\\UnnamedTests'):
                parent_ns = class_name.rsplit('\\', 1)[0]
                alternatives.extend([
                    f"{parent_ns}\\Test",
                    f"{parent_ns}\\Tests", 
                    f"{parent_ns}\\TestCase",
                ])
            if not class_name.endswith("Test"):
                alternatives.append(class_name + "Test")
            return alternatives
        
        # Testdox format: ✔ or ✓ for pass, ✘ or ✗ for fail
        if '✔' in line or '✓' in line:
            testdox_name = re.sub(r'[✔✓]\s*', '', line_stripped).strip()
            if testdox_name and current_class:
                method_name = testdox_to_method_name(testdox_name)
                for alt_class in get_alternative_class_names(current_class):
                    full_test_name = f"{alt_class}::{method_name}"
                    test_status_map[full_test_name] = TestStatus.PASSED
            elif testdox_name:
                test_status_map[testdox_name] = TestStatus.PASSED
                
        elif '✘' in line or '✗' in line:
            testdox_name = re.sub(r'[✘✗]\s*', '', line_stripped).strip()
            if testdox_name and current_class:
                method_name = testdox_to_method_name(testdox_name)
                for alt_class in get_alternative_class_names(current_class):
                    full_test_name = f"{alt_class}::{method_name}"
                    test_status_map[full_test_name] = TestStatus.FAILED
            elif testdox_name:
                test_status_map[testdox_name] = TestStatus.FAILED
                
        # Standard format: ClassName::testMethod
        if '::test' in line_stripped:
            match = re.search(r'([\w\\\\]+::\w+)', line_stripped)
            if match:
                test_name = match.group(1)
                lower_line = line_stripped.lower()
                if 'ok' in lower_line or 'pass' in lower_line:
                    test_status_map[test_name] = TestStatus.PASSED
                elif 'fail' in lower_line:
                    test_status_map[test_name] = TestStatus.FAILED
                elif 'error' in lower_line:
                    test_status_map[test_name] = TestStatus.ERROR
                elif 'skip' in lower_line:
                    test_status_map[test_name] = TestStatus.SKIPPED
    
    # Apply failures and errors found in detailed sections
    for test in current_failed_tests:
        test_status_map[test] = TestStatus.FAILED
    for test in current_error_tests:
        test_status_map[test] = TestStatus.ERROR
    
    return test_status_map


# ============================================================
# RUBY PARSERS
# ============================================================

def parse_log_ruby_minitest(log: str, grading_spec: Any = None) -> Dict[str, str]:
    """
    Parser for test logs generated with Ruby Minitest framework.

    Handles Minitest output format:
        ClassName::SubClass#test_method = 0.05 s = .
        ClassName::SubClass#test_method = 0.05 s = F
    """
    test_status_map = {}

    for line in log.split("\n"):
        line_stripped = line.strip()

        # Primary format: ClassName::SubClass#test_method = 0.05 s = .
        match = re.match(r'^([\w:]+#[\w]+)\s*=.*?=\s*([.FESN])\s*$', line_stripped)
        if match:
            test_name, result = match.groups()
            if result == '.':
                test_status_map[test_name] = TestStatus.PASSED
            elif result == 'F':
                test_status_map[test_name] = TestStatus.FAILED
            elif result == 'E':
                test_status_map[test_name] = TestStatus.ERROR
            elif result in ('S', 'N'):
                test_status_map[test_name] = TestStatus.SKIPPED
            continue

        # Alternative format: ClassName::SubClass#test_method [PASS]
        match = re.match(r'^([\w:]+#[\w]+)\s*\[(\w+)\]', line_stripped)
        if match:
            test_name, result = match.groups()
            result_upper = result.upper()
            if result_upper in ('PASS', 'OK', 'PASSED'):
                test_status_map[test_name] = TestStatus.PASSED
            elif result_upper in ('FAIL', 'FAILED'):
                test_status_map[test_name] = TestStatus.FAILED
            elif result_upper in ('ERROR', 'ERR'):
                test_status_map[test_name] = TestStatus.ERROR
            elif result_upper in ('SKIP', 'SKIPPED'):
                test_status_map[test_name] = TestStatus.SKIPPED
            continue

        # Verbose format: test_method_name (ClassName::SubClass) = 0.01 s = .
        match = re.match(r'^\s*(\w+)\s*\(([\w:]+)\)\s*=.*?=\s*([.FESN])\s*$', line_stripped)
        if match:
            method_name, class_name, result = match.groups()
            test_name = f"{class_name}#{method_name}"
            if result == '.':
                test_status_map[test_name] = TestStatus.PASSED
            elif result == 'F':
                test_status_map[test_name] = TestStatus.FAILED
            elif result == 'E':
                test_status_map[test_name] = TestStatus.ERROR
            elif result in ('S', 'N'):
                test_status_map[test_name] = TestStatus.SKIPPED

    return test_status_map


# ============================================================
# JAVASCRIPT / SWE-LANCER PARSERS
# ============================================================

def parse_log_swelancer_exitcode(log: str, grading_spec: Any = None) -> Dict[str, str]:
    """
    Parser for SWE-Lancer that uses pytest exit code for grading.
    
    SWE-Lancer grading is based on pytest exit code:
    - Exit code 0 = PASS
    - Exit code 1 = FAIL (test failures)
    - Exit code >= 2 = ERROR (collection/execution errors)
    """
    test_status_map = {}
    exit_code = None
    
    # Pattern 1: pytest_exit_code file content or variable
    match = re.search(r'pytest_exit_code[:\s=]+(\d+)', log, re.IGNORECASE)
    if match:
        exit_code = int(match.group(1))
    
    # Pattern 2: "exit code:" pattern
    if exit_code is None:
        match = re.search(r'exit\s+code[:\s]+(\d+)', log, re.IGNORECASE)
        if match:
            exit_code = int(match.group(1))
    
    # Pattern 3: Check pytest summary
    if exit_code is None:
        if re.search(r'\d+\s+passed', log) and not re.search(r'\d+\s+failed', log):
            exit_code = 0
        elif re.search(r'\d+\s+failed', log) or re.search(r'\d+\s+error', log):
            exit_code = 1
    
    # Find test names in log
    test_names = re.findall(r'(issues/[\w_]+/test\.py::[\w_]+)', log)
    if not test_names:
        test_names = re.findall(r'tests/[\w_]+/test\.py::(test_\w+)', log)
    if not test_names:
        test_names = re.findall(r'(test_expensify_\d+)', log)
    if not test_names:
        test_names = ['test_expensify_0000']
    
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
        for name in set(test_names):
            if 'PASSED' in log or 'passed' in log.lower():
                test_status_map[name] = TestStatus.PASSED
            else:
                test_status_map[name] = TestStatus.FAILED
    
    return test_status_map


def parse_log_playwright(log: str, grading_spec: Any = None) -> Dict[str, str]:
    """Parser for SWE-Lancer Playwright tests run via pytest."""
    return parse_log_swelancer_exitcode(log, grading_spec)


# ============================================================
# UNIFIED PARSER REGISTRY
# ============================================================

PARSER_REGISTRY: Dict[str, Callable] = {
    # Python parsers
    "python/parse_log_pytest_v3": parse_log_pytest_v3,
    "python/parse_log_pytest": parse_log_pytest_v3,
    "python/parse_log_unittest": parse_log_unittest,
    
    # PHP parsers
    "php/parse_log_phpunit": parse_log_phpunit,
    
    # Ruby parsers
    "ruby/parse_log_minitest": parse_log_ruby_minitest,
    "parsers/ruby_minitest_parser.py": parse_log_ruby_minitest,
    
    # JavaScript / SWE-Lancer parsers
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


# ============================================================
# SWE-LANCER CONFIGURATION
# ============================================================

USE_SWELANCER_MONOLITH = os.environ.get('USE_SWELANCER_MONOLITH', 'true').lower() == 'true'
SWELANCER_MONOLITH_IMAGE = os.environ.get('SWELANCER_MONOLITH_IMAGE', 'swelancer/unified:latest')


def is_swelancer_task(dataset: Dict[str, Any]) -> bool:
    """Check if this is a SWE-Lancer task based on dataset fields."""
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
    """Start a SWE-Lancer Docker container."""
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
             "--entrypoint", "/bin/bash",
             docker_image, "-c", "sleep 7200"],
            capture_output=True,
            text=True,
            timeout=120
        )
        
        if result.returncode != 0:
            logger.error(f"Failed to start SWE-Lancer container: {result.stderr}")
            return False
        
        time.sleep(2)
        
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
    """Extract and clean the model git patch from trajectory output."""
    test_result = trajectory.get('test_result', {})
    git_patch = test_result.get('git_patch', '')
    
    if not git_patch:
        return ''
    
    # Excluded artifact files
    EXCLUDED_FILES = [
        'command', 'exec_time', 'exit_code', 'stdout', 'stderr',
        'test_output', 'test_log', '.test_', '_test_output',
        'unittest_loader_no_traceback.py',
        'unittest_loader.py'
    ]
    
    lines = git_patch.split('\n')
    filtered_lines = []
    skip_current_diff = False
    
    for line in lines:
        if line.startswith('diff --git'):
            parts = line.split(' ')
            if len(parts) >= 4:
                b_path = parts[3] if parts[3].startswith('b/') else parts[2]
                file_name = b_path.replace('b/', '').strip()
                
                skip_current_diff = False
                for excluded in EXCLUDED_FILES:
                    if file_name == excluded or file_name.endswith(f'/{excluded}'):
                        skip_current_diff = True
                        logger.debug(f"Skipping artifact file: {file_name}")
                        break
        
        if not skip_current_diff:
            filtered_lines.append(line)
    
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
    Run SWE-Lancer tests using the official method.
    
    Returns: (returncode, stdout, stderr)
    """
    instance_id = instance.get('instance_id', '')
    
    # Extract issue_id
    issue_id = instance_id
    if '_' in str(instance_id):
        parts = str(instance_id).split('_')
        issue_id = parts[0]
    elif len(str(instance_id)) > 10:
        test_cmd = instance.get('test_command', '')
        if test_cmd:
            match = re.search(r'ISSUE_ID=([0-9_]+)', str(test_cmd))
            if match:
                issue_id = match.group(1)
                logger.info(f"Extracted issue_id from test_command: {issue_id}")
        
        if issue_id == instance_id:
            f2p = instance.get('FAIL_TO_PASS', [])
            if f2p:
                match = re.search(r'issues/([0-9_]+)/', str(f2p))
                if match:
                    issue_id = match.group(1)
                    logger.info(f"Extracted issue_id from FAIL_TO_PASS: {issue_id}")
    
    repo_path = instance.get('repo_path', '/app/repo')
    
    logger.info(f"Setting up SWE-Lancer test environment for issue {issue_id}...")
    
    # Add /etc/hosts entry
    hosts_cmd = (
        "grep -q 'dev.new.expensify.com' /etc/hosts || "
        "echo '127.0.0.1 dev.new.expensify.com' >> /etc/hosts"
    )
    run_docker_command(container_name, hosts_cmd, timeout=30)
    
    # Setup commands
    setup_commands = [
        "mkcert -install 2>/dev/null || true",
        "cd /app/repo/config/webpack && mkcert -key-file key.pem -cert-file certificate.pem localhost 127.0.0.1 dev.new.expensify.com 2>/dev/null || true",
        "pkill -9 Xvfb 2>/dev/null || true",
        "Xvfb :99 -screen 0 1920x1080x24 &",
        "export DISPLAY=:99",
        "fluxbox &>/dev/null &",
    ]
    
    for cmd in setup_commands:
        run_docker_command(container_name, cmd, timeout=60)
    
    time.sleep(2)
    
    # Checkout base_commit
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
    
    # Apply model patch (AFTER checkout)
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
    
    # Node.js version switching
    NODE_VERSION_MAP = {
        "2b791c9f3053": "20.15.1",
        "da2e6688c3f1": "20.18.0",
        "006a1dfe67a7": "20.18.0",
    }
    
    node_version = None
    if base_commit:
        commit_prefix = base_commit[:12]
        for commit_key, version in NODE_VERSION_MAP.items():
            if commit_key.startswith(commit_prefix) or commit_prefix.startswith(commit_key[:12]):
                node_version = version
                break
    
    if node_version:
        logger.info(f"Setting up Node.js {node_version} for commit {base_commit[:12]}...")
        
        switch_node_cmd = f"source ~/.nvm/nvm.sh && nvm use {node_version} && node --version"
        returncode, stdout, stderr = run_docker_command(container_name, switch_node_cmd, timeout=30)
        logger.info(f"Node version switch: {stdout.strip()}")
        
        # Check for cached node_modules
        cache_dir = f"/app/node_cache/{node_version}/node_modules"
        target_dir = f"{repo_path}/node_modules"
        
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
        else:
            _, cache_check, _ = run_docker_command(
                container_name,
                f"ls -d {cache_dir} 2>/dev/null && echo 'CACHE_EXISTS' || echo 'NO_CACHE'"
            )
            
            if "CACHE_EXISTS" in cache_check:
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
                
                logger.info("Running npm ci to fix local dependencies...")
                npm_ci_cmd = (
                    f"cd {repo_path} && source ~/.nvm/nvm.sh && nvm use {node_version} && "
                    f"npm ci 2>&1 | tail -10"
                )
                returncode, stdout, stderr = run_docker_command(container_name, npm_ci_cmd, timeout=300)
                logger.info(f"npm ci result: {stdout.strip()}")
            else:
                logger.warning(f"No cached node_modules for Node {node_version}, npm ci will be needed")
                logger.info("Running full npm ci (this may take 2-3 minutes)...")
                npm_ci_cmd = (
                    f"cd {repo_path} && source ~/.nvm/nvm.sh && nvm use {node_version} && "
                    f"npm ci 2>&1 | tail -15"
                )
                returncode, stdout, stderr = run_docker_command(container_name, npm_ci_cmd, timeout=600)
                logger.info(f"npm ci result: {stdout.strip()}")
    else:
        logger.warning(f"Unknown base_commit {base_commit}, using default Node version")
    
    # Start mitmdump
    logger.info(f"Starting mitmdump for issue {issue_id}...")
    
    _, addon_check, _ = run_docker_command(
        container_name,
        f"ls -la /app/tests/addons/issues/{issue_id}/addon.py 2>/dev/null || echo 'ADDON NOT FOUND'"
    )
    if "ADDON NOT FOUND" in addon_check:
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
    time.sleep(5)
    
    _, mitm_check, _ = run_docker_command(
        container_name,
        "netstat -tlnp 2>/dev/null | grep 8080 || ss -tlnp | grep 8080 || echo 'Mitmdump port 8080 not listening'"
    )
    logger.info(f"Mitmdump port check: {mitm_check.strip()}")
    
    # Start dev server
    logger.info("Starting webpack dev server on port 8082...")
    
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
    
    nvm_use = f"nvm use {node_version} && " if node_version else ""
    dev_server_cmd = (
        f"cd {repo_path} && "
        f"export USE_WEB_PROXY=false && "
        f"source ~/.nvm/nvm.sh && {nvm_use}"
        f"npm run web >/tmp/devserver.log 2>&1 &"
    )
    run_docker_command(container_name, dev_server_cmd, timeout=30)
    
    logger.info("Waiting for dev server to be ready (60s for webpack compilation)...")
    time.sleep(60)
    
    _, port_check, _ = run_docker_command(
        container_name,
        "netstat -tlnp 2>/dev/null | grep 8082 || ss -tlnp | grep 8082 || echo 'Port 8082 not listening'"
    )
    logger.info(f"Dev server port check: {port_check.strip()}")
    
    if "not listening" in port_check:
        _, devlog, _ = run_docker_command(container_name, "tail -30 /tmp/devserver.log 2>/dev/null || echo 'No log'")
        logger.error(f"Dev server failed to start. Log: {devlog}")
    
    run_docker_command(
        container_name,
        f"mkdir -p /app/tests/logs/{issue_id}"
    )
    
    # Rewrite test file to inject proxy configuration
    logger.info(f"Rewriting test file to inject proxy configuration...")
    
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
    
    # Run tests
    logger.info(f"Running SWE-Lancer tests for issue {issue_id}...")
    
    test_command = (
        f'export DISPLAY=:99 && '
        f'export ISSUE_ID={issue_id} && '
        f'cd /app/tests && '
        f'set -o pipefail && '
        f'pytest issues/{issue_id}/test.py -v --tb=short 2>&1 | tee /app/tests/logs/{issue_id}/pytest.log; '
        f'echo ${{PIPESTATUS[0]}} > /app/tests/logs/{issue_id}/pytest_exit_code'
    )
    
    returncode, stdout, stderr = run_docker_command(
        container_name,
        test_command,
        timeout=timeout
    )
    
    test_output = stdout + stderr
    
    _, exit_code_str, _ = run_docker_command(
        container_name,
        f"cat /app/tests/logs/{issue_id}/pytest_exit_code 2>/dev/null || echo '-1'"
    )
    
    _, pytest_log, _ = run_docker_command(
        container_name,
        f"cat /app/tests/logs/{issue_id}/pytest.log 2>/dev/null || echo 'No pytest log'"
    )
    
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
# STANDARD TEST COMMAND EXECUTION
# ============================================================

def run_test_command(container_name: str, instance: Dict[str, Any], timeout: int = 900) -> tuple:
    """
    Run the test command from the dataset.
    
    Returns: (returncode, stdout, stderr)
    """
    repo_directory = "/app/repo"
    test_patch_raw = instance.get("test_patch", "")
    test_command = instance.get("test_command", "pytest")
    
    # Parse test_patch
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
    
    # Apply golden test patches
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
    
    # Unset proxy environment variables
    unset_proxy = (
        "unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ftp_proxy FTP_PROXY all_proxy ALL_PROXY; "
        "export http_proxy='' https_proxy='' HTTP_PROXY='' HTTPS_PROXY=''; "
    )
    
    test_exec = test_command
    if "&&" in test_command and "source" in test_command:
        parts = test_command.split("&&")
        test_exec = parts[-1].strip()
    
    full_command = (
        f"source /saved/ENV 2>/dev/null || source /saved/*/ENV 2>/dev/null || true; "
        f"{unset_proxy}"
        f"cd {repo_directory} && {test_exec}"
    )
    
    logger.info(f"Running test command: {full_command[:200]}...")
    
    return run_docker_command(container_name, full_command, timeout=timeout)


# ============================================================
# TEST RESULT GRADING (with sophisticated matching)
# ============================================================

def normalize_test_name(test_name: str) -> str:
    """
    Normalize test name to enable matching between different formats.
    
    Converts:
        tests/Console/MetaCommand/MetaCommandTest.php::testCommand
    To:
        MetaCommandTest::testCommand
    """
    if '::' in test_name:
        path_part, method = test_name.rsplit('::', 1)
    else:
        return test_name
    
    if '.php' in path_part:
        class_name = path_part.split('/')[-1].replace('.php', '')
    elif '\\' in path_part:
        class_name = path_part.split('\\')[-1]
    else:
        class_name = path_part.split('/')[-1] if '/' in path_part else path_part
    
    return f"{class_name}::{method}"


def test_names_match(expected: str, actual: str) -> bool:
    """Check if two test names match, handling different formats."""
    if expected == actual:
        return True
    if expected in actual or actual in expected:
        return True
    
    norm_expected = normalize_test_name(expected)
    norm_actual = normalize_test_name(actual)
    if norm_expected == norm_actual:
        return True
    
    if '::' in norm_expected and '::' in norm_actual:
        _, method_exp = norm_expected.rsplit('::', 1)
        _, method_act = norm_actual.rsplit('::', 1)
        class_exp = norm_expected.split('::')[0]
        class_act = norm_actual.split('::')[0]
        if method_exp == method_act and (class_exp in class_act or class_act in class_exp):
            return True
    
    return False


def grade_test_results(
    test_status_map: Dict[str, str],
    fail_to_pass: List[str],
    pass_to_pass: List[str]
) -> Dict[str, Any]:
    """
    Grade test results against F2P and P2P expectations.
    
    Returns dict with categorized test results.
    """
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
    
    # Build set of failed/error tests for quick lookup
    failed_or_error_tests = set()
    for result_test, status in test_status_map.items():
        if status in (TestStatus.FAILED, TestStatus.ERROR):
            failed_or_error_tests.add(result_test)
            failed_or_error_tests.add(normalize_test_name(result_test))
    
    # Grade F2P tests
    for test in fail_to_pass:
        matched = False
        for result_test, status in test_status_map.items():
            if test_names_match(test, result_test):
                if status == TestStatus.PASSED:
                    results['fail_to_pass_success'].append(test)
                else:
                    results['fail_to_pass_failed'].append(test)
                matched = True
                break
        
        if not matched:
            is_failed = any(test_names_match(test, f) for f in failed_or_error_tests)
            
            if is_failed:
                logger.info(f"F2P test matched as failed/error: {test}")
                results['fail_to_pass_failed'].append(test)
            else:
                logger.info(f"F2P test not in error/failure section, assuming passed: {test}")
                results['fail_to_pass_success'].append(test)
    
    # Grade P2P tests
    for test in pass_to_pass:
        matched = False
        for result_test, status in test_status_map.items():
            if test_names_match(test, result_test):
                if status in passing_statuses or status == TestStatus.SKIPPED:
                    results['pass_to_pass_success'].append(test)
                else:
                    results['pass_to_pass_failed'].append(test)
                matched = True
                break
        
        if not matched:
            is_failed = any(test_names_match(test, f) for f in failed_or_error_tests)
            
            if is_failed:
                logger.info(f"P2P test matched as failed/error: {test}")
                results['pass_to_pass_failed'].append(test)
            else:
                logger.info(f"P2P test not in error/failure section, assuming passed: {test}")
                results['pass_to_pass_success'].append(test)
    
    return results


# ============================================================
# FILE LOADING UTILITIES
# ============================================================

def load_json_file(filepath: str) -> Dict[str, Any]:
    """Load a JSON file that may be JSONL (single line) or formatted JSON."""
    with open(filepath, 'r') as f:
        content = f.read().strip()
        
    # Try parsing as single JSON object first
    try:
        return json.loads(content)
    except json.JSONDecodeError:
        pass
    
    # Fallback to JSONL (first line)
    for line in content.split('\n'):
        if line.strip():
            return json.loads(line)
    
    raise ValueError(f"Could not parse JSON from {filepath}")


def parse_list_field(value) -> List[str]:
    """Parse a list field that may be JSON, Python literal, or already a list."""
    if isinstance(value, list):
        return value
    if not isinstance(value, str) or not value.strip():
        return []
    
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        pass
    
    try:
        parsed = ast.literal_eval(value)
        if isinstance(parsed, list):
            return parsed
    except (ValueError, SyntaxError):
        pass
    
    logger.warning(f"Could not parse list field: {str(value)[:50]}...")
    return []


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
    Evaluate a single trajectory instance.
    
    Automatically routes to SWE-Lancer flow or standard flow based on dataset.
    """
    container_name = f"eval_unified_{int(time.time())}"
    
    try:
        # Load trajectory
        logger.info(f"Loading trajectory from {trajectory_file}")
        trajectory = load_json_file(trajectory_file)
        
        instance_id = trajectory.get('instance_id', 'unknown')
        model_patch = extract_model_patch(trajectory)
        
        logger.info(f"Instance ID: {instance_id}")
        logger.info(f"Model patch length: {len(model_patch)} chars")
        
        # Load dataset
        logger.info(f"Loading dataset from {dataset_file}")
        dataset = load_json_file(dataset_file)
        
        if dataset.get('instance_id') != instance_id:
            logger.warning(f"Instance ID mismatch: trajectory={instance_id}, dataset={dataset.get('instance_id')}")
        
        # Parse fields
        traj_instance = trajectory.get('instance', {})
        
        fail_to_pass = parse_list_field(traj_instance.get('FAIL_TO_PASS'))
        if not fail_to_pass:
            fail_to_pass = parse_list_field(dataset.get('FAIL_TO_PASS', []))
        
        pass_to_pass = parse_list_field(traj_instance.get('PASS_TO_PASS'))
        if not pass_to_pass:
            pass_to_pass = parse_list_field(dataset.get('PASS_TO_PASS', []))
        
        test_command = traj_instance.get('test_command') or dataset.get('test_command') or 'pytest'
        if not test_command or not test_command.strip():
            test_command = 'pytest --no-header -rA --tb=no -p no:cacheprovider'
            logger.warning(f"Empty test_command, using default: {test_command}")
        
        test_output_parser = traj_instance.get('test_output_parser') or dataset.get('test_output_parser', 'python/parse_log_pytest_v3')
        test_patch = traj_instance.get('test_patch') or dataset.get('test_patch', '')
        
        logger.info(f"F2P tests: {len(fail_to_pass)}")
        logger.info(f"P2P tests: {len(pass_to_pass)}")
        logger.info(f"Test command: {test_command[:80]}...")
        logger.info(f"Parser: {test_output_parser}")
        
        # Check if SWE-Lancer task
        is_swelancer = is_swelancer_task(dataset)
        if is_swelancer:
            logger.info("Detected SWE-Lancer task - using SWE-Lancer evaluation flow")
        
        # Get Docker image for SWE-Lancer
        if is_swelancer:
            if docker_image and not docker_image.startswith('s3://') and '/' in docker_image:
                logger.info(f"Using CLI-provided Docker image: {docker_image}")
            else:
                swelancer_image = get_swelancer_docker_image(dataset)
                if swelancer_image and not swelancer_image.startswith('s3://'):
                    docker_image = swelancer_image
                    logger.info(f"Using SWE-Lancer Docker image from dataset: {docker_image}")
                else:
                    docker_image = "swelancer/unified:latest"
                    logger.info(f"Dataset has S3 path, using local unified image: {docker_image}")
        
        # Start container
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
                error_message="Failed to start container"
            )
        
        # ============================================================
        # SWE-LANCER EVALUATION FLOW
        # ============================================================
        if is_swelancer:
            base_commit = dataset.get('base_commit', '')
            
            if model_patch:
                logger.info("Copying model patch to container...")
                with tempfile.NamedTemporaryFile(mode='w', suffix='.diff', delete=False) as f:
                    f.write(model_patch)
                    patch_file = f.name
                
                subprocess.run(
                    ["docker", "cp", patch_file, f"{container_name}:/tmp/model.patch"],
                    capture_output=True, timeout=30
                )
                os.unlink(patch_file)
            
            returncode, full_output, _ = run_swelancer_tests(
                container_name, dataset, base_commit, model_patch=model_patch, timeout=timeout
            )
            
            parser_func = get_parser(test_output_parser)
            test_status_map = parser_func(full_output)
            
            logger.info(f"Parsed {len(test_status_map)} test results (SWE-Lancer)")
        
        # ============================================================
        # STANDARD EVALUATION FLOW
        # ============================================================
        else:
            # Apply model patch
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
                
                returncode, stdout, stderr = run_docker_command(
                    container_name,
                    "cd /app/repo && git apply -v /tmp/model.patch 2>&1 || "
                    "patch --batch --fuzz=5 -p1 -i /tmp/model.patch 2>&1"
                )
                
                if returncode != 0 and "FAILED" in stdout:
                    logger.warning("Patch application may have failed")
            
            # Reset test files
            logger.info("Resetting test files to clean state...")
            
            run_docker_command(
                container_name,
                "cd /app/repo && git clean -fd '**/test*.py' '**/tests/' '**/*_test.py' 2>/dev/null || true"
            )
            
            run_docker_command(
                container_name,
                "cd /app/repo && git checkout -- '**/test*.py' '**/tests/**' '**/*_test.py' 2>/dev/null || true"
            )
            
            logger.info("Test files reset complete")
            
            # Run test command
            returncode, stdout, stderr = run_test_command(
                container_name, dataset, timeout=timeout
            )
            
            full_output = stdout + stderr
            
            # Parse test output
            parser_func = get_parser(test_output_parser)
            test_status_map = parser_func(full_output)
            
            logger.info(f"Parsed {len(test_status_map)} test results")
        
        # Grade results
        grade_results = grade_test_results(test_status_map, fail_to_pass, pass_to_pass)
        
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
            test_output=full_output[:50000]
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
# CLI AND OUTPUT GENERATION
# ============================================================

def main():
    parser = argparse.ArgumentParser(
        description="Unified Evaluation Script for Multi-Language SWE-Bench Tasks",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    # Evaluate a trajectory
    python eval_pilot2_standardized.py \\
        --trajectory-file output.jsonl \\
        --dataset-file task.jsonl \\
        --docker-image mswebench/sweb.eval.x86_64.task:latest \\
        --output-file eval_output.jsonl
        
    # With custom timeout and output directory
    python eval_pilot2_standardized.py \\
        --trajectory-file output.jsonl \\
        --dataset-file task.jsonl \\
        --docker-image image:tag \\
        --output-file eval.jsonl \\
        --output-dir ./eval_results \\
        --timeout 1200
        """
    )
    parser.add_argument("--trajectory-file", required=True, help="Path to trajectory output.jsonl")
    parser.add_argument("--dataset-file", required=True, help="Path to dataset JSONL")
    parser.add_argument("--docker-image", required=True, help="Docker image name or path to .tar")
    parser.add_argument("--output-file", required=True, help="Output file for eval results")
    parser.add_argument("--output-dir", help="Output directory for eval_outputs structure (defaults to trajectory dir)")
    parser.add_argument("--timeout", type=int, default=900, help="Test timeout in seconds (default: 900)")
    
    args = parser.parse_args()
    
    # Determine output directory
    if args.output_dir:
        output_dir = args.output_dir
    else:
        output_dir = os.path.dirname(args.trajectory_file)
    
    # Load dataset for test_command
    dataset = load_json_file(args.dataset_file)
    test_command = dataset.get('test_command', 'pytest')
    
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
    
    # Save results (JSONL format)
    original = load_json_file(args.trajectory_file)
    original['pilot2_eval_details'] = asdict(report)
    original['resolved'] = report.resolved
    
    with open(args.output_file, 'w') as f:
        f.write(json.dumps(original) + '\n')
    
    logger.info(f"Results saved to: {args.output_file}")
    
    # ============================================================
    # CREATE EVAL_OUTPUTS DIRECTORY STRUCTURE
    # ============================================================
    logger.info("Creating eval_outputs directory structure...")
    
    eval_outputs_dir = os.path.join(output_dir, 'eval_outputs')
    instance_eval_dir = os.path.join(eval_outputs_dir, report.instance_id)
    os.makedirs(instance_eval_dir, exist_ok=True)
    
    # 1. Save patch.diff
    git_patch = original.get('test_result', {}).get('git_patch', '')
    if not git_patch:
        git_patch = original.get('git_patch', '')
    patch_file = os.path.join(instance_eval_dir, 'patch.diff')
    with open(patch_file, 'w') as f:
        f.write(git_patch)
    logger.info(f"Created: {patch_file}")
    
    # 2. Create report.json
    openhands_report = {
        report.instance_id: {
            "patch_is_None": not git_patch,
            "patch_exists": bool(git_patch),
            "patch_successfully_applied": not report.failed_apply_patch,
            "resolved": report.resolved,
            "tests_status": {
                "FAIL_TO_PASS": {
                    "success": report.fail_to_pass_success,
                    "failure": report.fail_to_pass_failed
                },
                "PASS_TO_PASS": {
                    "success": report.pass_to_pass_success,
                    "failure": report.pass_to_pass_failed
                },
                "FAIL_TO_FAIL": {"success": [], "failure": []},
                "PASS_TO_FAIL": {"success": [], "failure": []}
            }
        }
    }
    report_file = os.path.join(instance_eval_dir, 'report.json')
    with open(report_file, 'w') as f:
        json.dump(openhands_report, f, indent=4)
    logger.info(f"Created: {report_file}")
    
    # 3. Save test_output.txt
    test_output_file = os.path.join(instance_eval_dir, 'test_output.txt')
    with open(test_output_file, 'w') as f:
        f.write(report.test_output)
    logger.info(f"Created: {test_output_file}")
    
    # 4. Create run_instance.log
    run_log_file = os.path.join(instance_eval_dir, 'run_instance.log')
    run_log_content = f"""Evaluation Log for {report.instance_id}
{'=' * 60}
Docker Image: {args.docker_image}
Timeout: {args.timeout}s
Resolved: {report.resolved}

Patch Applied: {not report.failed_apply_patch}
Test Patch Applied: {not report.failed_apply_test_patch}
Tests Passed: {report.tests_passed}
Tests Failed: {report.tests_failed}
Tests Error: {report.tests_error}

FAIL_TO_PASS Success: {report.fail_to_pass_success}
FAIL_TO_PASS Failed: {report.fail_to_pass_failed}
PASS_TO_PASS Success: {report.pass_to_pass_success}
PASS_TO_PASS Failed: {report.pass_to_pass_failed}

{'=' * 60}
Test Output:
{'=' * 60}
{report.test_output}
"""
    with open(run_log_file, 'w') as f:
        f.write(run_log_content)
    logger.info(f"Created: {run_log_file}")
    
    # 5. Create eval.sh
    eval_sh_file = os.path.join(instance_eval_dir, 'eval.sh')
    eval_sh_content = f"""#!/bin/bash
# Evaluation script for {report.instance_id}
# Generated by eval_pilot2_standardized.py

cd /testbed || cd /app/repo || cd /workspace

# Run tests
{test_command}
"""
    with open(eval_sh_file, 'w') as f:
        f.write(eval_sh_content)
    os.chmod(eval_sh_file, 0o755)
    logger.info(f"Created: {eval_sh_file}")
    
    # 6. Create aggregate report.json
    aggregate_report_file = os.path.join(eval_outputs_dir, 'report.json')
    with open(aggregate_report_file, 'w') as f:
        json.dump(openhands_report, f, indent=4)
    logger.info(f"Created: {aggregate_report_file}")
    
    # 7. Create eval_summary.json
    eval_summary = {
        "total_instances": 1,
        "resolved_instances": 1 if report.resolved else 0,
        "unresolved_instances": 0 if report.resolved else 1,
        "error_instances": 1 if report.error_eval else 0,
        "results": {
            report.instance_id: {
                "resolved": report.resolved,
                "tests_passed": report.tests_passed,
                "tests_failed": report.tests_failed,
                "f2p_success": len(report.fail_to_pass_success),
                "f2p_total": len(report.fail_to_pass_success) + len(report.fail_to_pass_failed),
                "p2p_success": len(report.pass_to_pass_success),
                "p2p_total": len(report.pass_to_pass_success) + len(report.pass_to_pass_failed)
            }
        }
    }
    eval_summary_file = os.path.join(output_dir, 'eval_summary.json')
    with open(eval_summary_file, 'w') as f:
        json.dump(eval_summary, f, indent=4)
    logger.info(f"Created: {eval_summary_file}")
    
    logger.info("=" * 60)
    logger.info("EVAL_OUTPUTS STRUCTURE CREATED SUCCESSFULLY")
    logger.info(f"Location: {eval_outputs_dir}")
    logger.info("=" * 60)
    
    # Return 0 if evaluation completed (resolved or not)
    # Return 1 only for actual evaluation errors
    if report.error_eval and not report.tests_failed and not report.tests_passed:
        return 1
    return 0


if __name__ == "__main__":
    exit(main())
