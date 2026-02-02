#!/usr/bin/env python3
"""
Velora3 Multi-Language Evaluation Script

Extended evaluation script for validating F2P tests across multiple languages:
- Java (JUnit/Maven)
- Rust (Cargo test)
- Go (go test)
- C/C++ (meson test, make test)
- Python (pytest, unittest)

This script:
1. Loads trajectory with potentially empty F2P/P2P
2. Injects extracted F2P tests from our extraction script
3. Uses language-specific test output parsers
4. Grades results against F2P/P2P expectations

Usage:
    python velora3_eval_multilang.py \
        --trajectory-file output.jsonl \
        --f2p-file extracted_f2p_tests.jsonl \
        --instance-id 1768220728110174 \
        --docker-image mswebench/task:latest \
        --output-file eval_output.jsonl
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


# ============================================================================
# TEST STATUS ENUM
# ============================================================================

class TestStatus:
    """Test status values."""
    PASSED = "PASSED"
    FAILED = "FAILED"
    ERROR = "ERROR"
    SKIPPED = "SKIPPED"
    XFAIL = "XFAIL"
    XPASS = "XPASS"


# ============================================================================
# MULTI-LANGUAGE LOG PARSERS
# ============================================================================

def parse_log_pytest_v3(log: str, grading_spec: Any = None) -> Dict[str, str]:
    """Parser for pytest output."""
    test_status_map = {}
    escapes = "".join([chr(char) for char in range(1, 32)])
    translator = str.maketrans("", "", escapes)
    
    status_values = "|".join([TestStatus.PASSED, TestStatus.FAILED, TestStatus.ERROR, 
                              TestStatus.SKIPPED, TestStatus.XFAIL, TestStatus.XPASS])
    status_pattern = re.compile(rf"^({status_values})\s+")
    
    for line in log.split("\n"):
        line = re.sub(r"\[(\d+)m", "", line)
        line = line.translate(translator)
        line = line.replace(" - ", " ")
        
        match = status_pattern.match(line)
        if match:
            test_case = line.split()
            if len(test_case) >= 2:
                test_status_map[test_case[1]] = test_case[0]
    
    return test_status_map


def parse_log_junit(log: str, grading_spec: Any = None) -> Dict[str, str]:
    """
    Parser for JUnit/Maven test output.
    
    Handles formats like:
    - [INFO] Tests run: 5, Failures: 0, Errors: 0, Skipped: 0
    - Running com.example.TestClass
    - Tests run: 1, Failures: 1, Errors: 0
    """
    test_status_map = {}
    current_test_class = None
    
    # Check for compilation failure first
    if 'COMPILATION ERROR' in log or ('cannot find symbol' in log and 'BUILD FAILURE' in log):
        # Compilation failed - mark this as detected but no tests ran
        return {'COMPILATION_FAILED': TestStatus.FAILED}
    
    lines = log.split('\n')
    
    for i, line in enumerate(lines):
        # Track current test class
        if 'Running ' in line and not 'Running tests' in line:
            match = re.search(r'Running\s+([\w\.]+)', line)
            if match:
                current_test_class = match.group(1)
        
        # Look for individual test results
        # Pattern: "Tests run: X, Failures: Y, Errors: Z, Skipped: W, Time elapsed: T"
        if 'Tests run:' in line and current_test_class:
            match = re.search(r'Tests run:\s*(\d+),\s*Failures:\s*(\d+),\s*Errors:\s*(\d+)', line)
            if match:
                total, failures, errors = int(match.group(1)), int(match.group(2)), int(match.group(3))
                if failures == 0 and errors == 0:
                    test_status_map[current_test_class] = TestStatus.PASSED
                elif errors > 0:
                    test_status_map[current_test_class] = TestStatus.ERROR
                else:
                    test_status_map[current_test_class] = TestStatus.FAILED
        
        # Look for specific test method failures
        # Pattern: "[ERROR] testMethodName(TestClass) Time elapsed: 0.1 s <<< FAILURE!"
        if '<<< FAILURE!' in line or '<<< ERROR!' in line:
            match = re.search(r'(\w+)\([\w\.]+\)', line)
            if match:
                test_name = match.group(1)
                if '<<< ERROR!' in line:
                    test_status_map[test_name] = TestStatus.ERROR
                else:
                    test_status_map[test_name] = TestStatus.FAILED
        
        # Look for @Test method pattern in surefire reports
        # Pattern: "test_method_name(TestClass): failure message"
        match = re.search(r'^(test\w+)\([^)]+\)', line)
        if match and ': ' in line:
            test_name = match.group(1)
            if 'PASSED' not in line:
                test_status_map[test_name] = TestStatus.FAILED
    
    # Look for passed tests in the summary
    # If we see "BUILD SUCCESS" and individual test classes passed
    if 'BUILD SUCCESS' in log:
        # Mark all test classes we found as passed if not already marked
        for test_class in re.findall(r'Running\s+([\w\.]+)', log):
            if test_class not in test_status_map:
                test_status_map[test_class] = TestStatus.PASSED
    
    return test_status_map


def parse_log_cargo_test(log: str, grading_spec: Any = None) -> Dict[str, str]:
    """
    Parser for Rust cargo test output.
    
    Handles formats like:
    - test test_name ... ok
    - test test_name ... FAILED
    - test result: ok. 10 passed; 0 failed; 0 ignored
    """
    test_status_map = {}
    
    for line in log.split('\n'):
        line = line.strip()
        
        # Pattern: "test module::test_name ... ok" or "test test_name ... FAILED"
        match = re.match(r'^test\s+([\w:]+)\s+\.\.\.\s+(\w+)', line)
        if match:
            test_name = match.group(1)
            result = match.group(2).upper()
            
            if result == 'OK':
                test_status_map[test_name] = TestStatus.PASSED
            elif result == 'FAILED':
                test_status_map[test_name] = TestStatus.FAILED
            elif result == 'IGNORED':
                test_status_map[test_name] = TestStatus.SKIPPED
    
    return test_status_map


def parse_log_go_test(log: str, grading_spec: Any = None) -> Dict[str, str]:
    """
    Parser for Go test output.
    
    Handles formats like:
    - --- PASS: TestName (0.00s)
    - --- FAIL: TestName (0.00s)
    - === RUN   TestName
    - PASS
    - FAIL
    """
    test_status_map = {}
    
    # Check for build/compile failures first
    if ('no required module provides package' in log or 
        '[setup failed]' in log or
        'cannot find package' in log or
        'build failed' in log.lower()):
        return {'BUILD_FAILED': TestStatus.FAILED}
    
    for line in log.split('\n'):
        line = line.strip()
        
        # Pattern: "--- PASS: TestName (time)"
        match = re.match(r'^---\s+(PASS|FAIL|SKIP):\s+(\w+)', line)
        if match:
            result, test_name = match.groups()
            if result == 'PASS':
                test_status_map[test_name] = TestStatus.PASSED
            elif result == 'FAIL':
                test_status_map[test_name] = TestStatus.FAILED
            elif result == 'SKIP':
                test_status_map[test_name] = TestStatus.SKIPPED
        
        # Pattern: "=== RUN   TestName" followed by "--- PASS/FAIL"
        if line.startswith('=== RUN'):
            match = re.match(r'^=== RUN\s+(\w+)', line)
            if match:
                # Will be updated by the PASS/FAIL line
                pass
    
    return test_status_map


def parse_log_meson(log: str, grading_spec: Any = None) -> Dict[str, str]:
    """
    Parser for meson test output.
    
    Handles formats like:
    - 1/5 test_name          OK             0.12s
    - 2/5 test_name          FAIL           0.05s
    - Ok:                 4
    - Fail:               1
    """
    test_status_map = {}
    
    for line in log.split('\n'):
        line = line.strip()
        
        # Pattern: "1/5 test_name          OK             0.12s"
        match = re.match(r'^\d+/\d+\s+([\w_-]+)\s+(OK|FAIL|SKIP|TIMEOUT|ERROR)', line)
        if match:
            test_name, result = match.groups()
            if result == 'OK':
                test_status_map[test_name] = TestStatus.PASSED
            elif result in ['FAIL', 'ERROR', 'TIMEOUT']:
                test_status_map[test_name] = TestStatus.FAILED
            elif result == 'SKIP':
                test_status_map[test_name] = TestStatus.SKIPPED
    
    return test_status_map


def parse_log_make(log: str, grading_spec: Any = None) -> Dict[str, str]:
    """
    Generic parser for make test output.
    Attempts to parse various test framework outputs.
    """
    test_status_map = {}
    
    # Try go test patterns
    go_results = parse_log_go_test(log)
    test_status_map.update(go_results)
    
    # Try meson patterns
    meson_results = parse_log_meson(log)
    test_status_map.update(meson_results)
    
    # Generic patterns
    for line in log.split('\n'):
        line = line.strip()
        
        # Pattern: "PASS: test_name" or "FAIL: test_name"
        match = re.match(r'^(PASS|FAIL|ERROR|SKIP):\s*(.+)', line)
        if match:
            result, test_name = match.groups()
            test_name = test_name.strip()
            if result == 'PASS':
                test_status_map[test_name] = TestStatus.PASSED
            elif result in ['FAIL', 'ERROR']:
                test_status_map[test_name] = TestStatus.FAILED
            elif result == 'SKIP':
                test_status_map[test_name] = TestStatus.SKIPPED
    
    return test_status_map


def parse_log_playwright(log: str, grading_spec: Any = None) -> Dict[str, str]:
    """
    Parser for SWE-Lancer Playwright tests run via pytest.
    
    SWE-Lancer uses Python tests with Playwright for browser automation.
    The tests are run via pytest and grading is primarily based on exit code.
    
    Handles formats like:
    - pytest summary: "1 passed in 45.23s"
    - pytest summary: "1 failed, 0 passed in 30.12s"
    - pytest exit codes in log
    - test function names: test_expensify_0000
    """
    test_status_map = {}
    
    # Check for pytest exit code (SWE-Lancer specific)
    exit_code_match = re.search(r'pytest_exit_code[:\s]+(\d+)', log)
    if exit_code_match:
        exit_code = int(exit_code_match.group(1))
        if exit_code == 0:
            # All tests passed - mark any found tests as passed
            for match in re.finditer(r'(test_\w+)', log):
                test_status_map[match.group(1)] = TestStatus.PASSED
            if not test_status_map:
                test_status_map['all_tests'] = TestStatus.PASSED
            return test_status_map
    
    # Check for pytest summary line
    # Pattern: "1 passed" or "1 failed" or "1 passed, 1 failed"
    passed_match = re.search(r'(\d+)\s+passed', log)
    failed_match = re.search(r'(\d+)\s+failed', log)
    error_match = re.search(r'(\d+)\s+error', log)
    
    # Look for specific test function names
    test_funcs = re.findall(r'(test_expensify_\d+|test_\w+::\w+)', log)
    
    # Determine overall status from summary
    has_failures = (failed_match and int(failed_match.group(1)) > 0) or \
                   (error_match and int(error_match.group(1)) > 0)
    has_passes = passed_match and int(passed_match.group(1)) > 0
    
    # If we found test function names, use them
    if test_funcs:
        for test_name in set(test_funcs):
            if has_failures:
                test_status_map[test_name] = TestStatus.FAILED
            elif has_passes:
                test_status_map[test_name] = TestStatus.PASSED
            else:
                test_status_map[test_name] = TestStatus.FAILED
    else:
        # Generic result based on summary
        if has_failures:
            test_status_map['test_expensify_0000'] = TestStatus.FAILED
        elif has_passes:
            test_status_map['test_expensify_0000'] = TestStatus.PASSED
    
    # Also check for PASSED/FAILED patterns in log
    for line in log.split('\n'):
        line = line.strip()
        # Pattern: "PASSED tests/12155_1/test.py::test_expensify_0000"
        match = re.match(r'^(PASSED|FAILED|ERROR)\s+(.+)', line)
        if match:
            status, test_path = match.groups()
            # Extract test name from path
            if '::' in test_path:
                test_name = test_path.split('::')[-1]
            else:
                test_name = test_path
            test_status_map[test_name] = status
    
    return test_status_map


def parse_log_swelancer_exitcode(log: str, grading_spec: Any = None) -> Dict[str, str]:
    """
    Parser for SWE-Lancer that uses pytest exit code for grading.
    
    This is the official SWE-Lancer grading method:
    - Exit code 0 = PASS
    - Exit code 1 = FAIL (test failures)
    - Exit code >= 2 = ERROR (collection/execution errors)
    
    The log should contain the pytest exit code from:
    /app/tests/logs/<ISSUE_ID>/pytest_exit_code
    """
    test_status_map = {}
    
    # Look for exit code patterns
    exit_code = None
    
    # Pattern 1: Direct exit code
    match = re.search(r'pytest_exit_code[:\s=]+(\d+)', log, re.IGNORECASE)
    if match:
        exit_code = int(match.group(1))
    
    # Pattern 2: Exit code at end of output
    if exit_code is None:
        match = re.search(r'exit\s+code[:\s]+(\d+)', log, re.IGNORECASE)
        if match:
            exit_code = int(match.group(1))
    
    # Pattern 3: Return code
    if exit_code is None:
        match = re.search(r'return\s*code[:\s]+(\d+)', log, re.IGNORECASE)
        if match:
            exit_code = int(match.group(1))
    
    # Find test names in log
    test_names = re.findall(r'tests/[\w_]+/test\.py::(\w+)', log)
    if not test_names:
        test_names = re.findall(r'(test_expensify_\d+)', log)
    if not test_names:
        test_names = ['test_expensify_0000']  # Default
    
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
        # Fallback to log parsing if no exit code found
        return parse_log_playwright(log, grading_spec)
    
    return test_status_map


# Parser registry
PARSER_REGISTRY: Dict[str, Callable] = {
    "python/parse_log_pytest_v3": parse_log_pytest_v3,
    "python/parse_log_pytest": parse_log_pytest_v3,
    "python/parse_log_unittest": parse_log_pytest_v3,  # Similar enough
    "java/parse_log_junit": parse_log_junit,
    "rust/parse_log_cargo_test": parse_log_cargo_test,
    "go/parse_log_go_test": parse_log_go_test,
    "go/parse_log_gotest": parse_log_go_test,
    "c/parse_log_meson": parse_log_meson,
    "cpp/parse_log_meson": parse_log_meson,
    "generic/parse_log_make": parse_log_make,
    # SWE-Lancer Playwright parsers
    "javascript/parse_log_playwright": parse_log_playwright,
    "swelancer/parse_log_playwright": parse_log_playwright,
    "swelancer/parse_log_exitcode": parse_log_swelancer_exitcode,
}


def get_parser(parser_name: str) -> Callable:
    """Get parser function by name."""
    # Normalize parser name
    parser_name = parser_name.strip().lower()
    
    for key, func in PARSER_REGISTRY.items():
        if key.lower() == parser_name or key.split('/')[-1].lower() == parser_name:
            return func
    
    logger.warning(f"Unknown parser '{parser_name}', using generic make parser")
    return parse_log_make


# ============================================================================
# EVAL REPORT DATACLASS
# ============================================================================

@dataclass
class EvalReport:
    """Evaluation report for a single instance."""
    instance_id: str
    velora_instance_id: str
    job_name: str
    language: str
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
    f2p_validation_notes: str = ""


# ============================================================================
# PATCH FILTERING (from Pilot 2)
# ============================================================================

# Files to exclude from model patches (OpenHands artifacts)
EXCLUDED_FILES = [
    'command',
    'exec_time', 
    'exit_code',
    '.openhands_state',
]

def filter_model_patch(git_patch: str) -> str:
    """
    Filter out OpenHands artifacts and non-code files from model patches.
    
    This matches Pilot 2's filter_git_patch() function.
    """
    if not git_patch:
        return ""
    
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
                        logger.debug(f"Filtering artifact file: {file_name}")
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


# ============================================================================
# F2P INJECTION
# ============================================================================

def load_extracted_f2p(f2p_file: str, velora_instance_id: str) -> Dict[str, Any]:
    """Load extracted F2P tests for a specific instance."""
    with open(f2p_file, 'r') as f:
        for line in f:
            if line.strip():
                data = json.loads(line)
                if data.get('velora_instance_id') == velora_instance_id:
                    return data
    return {}


def inject_f2p_into_trajectory(trajectory: Dict[str, Any], f2p_data: Dict[str, Any]) -> Dict[str, Any]:
    """
    Inject extracted F2P tests into trajectory's instance field.
    
    This modifies the trajectory in-place to add the F2P tests we extracted.
    """
    instance = trajectory.get('instance', {})
    
    # Get F2P test names from extracted data
    f2p_tests = list(f2p_data.get('f2p_tests', {}).keys())
    p2p_tests = list(f2p_data.get('p2p_tests', {}).keys())
    
    # Inject into instance
    instance['FAIL_TO_PASS'] = f2p_tests
    instance['PASS_TO_PASS'] = p2p_tests
    
    # Also update test_patch if we have it
    if 'test_patch' in f2p_data and f2p_data['test_patch']:
        instance['test_patch'] = f2p_data['test_patch']
    
    trajectory['instance'] = instance
    
    logger.info(f"Injected {len(f2p_tests)} F2P tests and {len(p2p_tests)} P2P tests")
    
    return trajectory


# ============================================================================
# DOCKER OPERATIONS
# ============================================================================

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
        subprocess.run(["docker", "rm", "-f", container_name], capture_output=True, timeout=30)
    except:
        pass
    
    try:
        result = subprocess.run(
            ["docker", "run", "-d", "--name", container_name, 
             "--entrypoint", "/bin/bash", docker_image, "-c", "sleep 3600"],
            capture_output=True, text=True, timeout=120
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


# ============================================================================
# PATCH EXTRACTION
# ============================================================================

def extract_model_patch(trajectory: Dict[str, Any]) -> str:
    """Extract the model git patch from trajectory output."""
    test_result = trajectory.get('test_result', {})
    git_patch = test_result.get('git_patch', '')
    
    # Ensure patch ends with newline (required by git apply)
    if git_patch and not git_patch.endswith('\n'):
        git_patch = git_patch + '\n'
    
    if not git_patch:
        return ''
    
    # Filter out artifact files
    EXCLUDED_FILES = ['command', 'exec_time', 'exit_code', 'stdout', 'stderr']
    
    lines = git_patch.split('\n')
    filtered_lines = []
    skip_current_diff = False
    
    for line in lines:
        if line.startswith('diff --git'):
            parts = line.split(' ')
            if len(parts) >= 4:
                b_path = parts[3] if parts[3].startswith('b/') else parts[2]
                file_name = b_path.replace('b/', '').strip()
                skip_current_diff = any(file_name == ex or file_name.endswith(f'/{ex}') 
                                       for ex in EXCLUDED_FILES)
        
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


# ============================================================================
# TEST GRADING
# ============================================================================

def grade_test_results(
    test_status_map: Dict[str, str],
    fail_to_pass: List[str],
    pass_to_pass: List[str]
) -> Dict[str, Any]:
    """Grade test results against F2P and P2P expectations."""
    
    passing_statuses = {TestStatus.PASSED, TestStatus.XFAIL, TestStatus.XPASS}
    
    results = {
        'tests_passed': sum(1 for s in test_status_map.values() if s in passing_statuses),
        'tests_failed': sum(1 for s in test_status_map.values() if s == TestStatus.FAILED),
        'tests_error': sum(1 for s in test_status_map.values() if s == TestStatus.ERROR),
        'fail_to_pass_success': [],
        'fail_to_pass_failed': [],
        'pass_to_pass_success': [],
        'pass_to_pass_failed': [],
    }
    
    # Grade F2P tests
    for test in fail_to_pass:
        matched = False
        for result_test, status in test_status_map.items():
            # Flexible matching
            if (test == result_test or 
                test in result_test or 
                result_test in test or
                test.lower() in result_test.lower() or
                result_test.lower() in test.lower()):
                if status == TestStatus.PASSED:
                    results['fail_to_pass_success'].append(test)
                else:
                    results['fail_to_pass_failed'].append(test)
                matched = True
                break
        
        if not matched:
            logger.warning(f"F2P test not found in output: {test}")
            results['fail_to_pass_failed'].append(test)
    
    # Grade P2P tests
    for test in pass_to_pass:
        matched = False
        for result_test, status in test_status_map.items():
            if (test == result_test or 
                test in result_test or 
                result_test in test):
                if status in passing_statuses or status == TestStatus.SKIPPED:
                    results['pass_to_pass_success'].append(test)
                else:
                    results['pass_to_pass_failed'].append(test)
                matched = True
                break
        
        if not matched:
            results['pass_to_pass_failed'].append(test)
    
    return results


# ============================================================================
# MAIN EVALUATION
# ============================================================================

def evaluate_instance(
    trajectory_file: str,
    f2p_file: str,
    velora_instance_id: str,
    docker_image: str,
    timeout: int = 900,
    test_patch_file: Optional[str] = None,
    csv_f2p_file: Optional[str] = None
) -> EvalReport:
    """
    Evaluate a trajectory with injected F2P tests.
    
    Args:
        trajectory_file: Path to trajectory output.jsonl
        f2p_file: Path to extracted F2P tests JSONL
        velora_instance_id: Velora instance ID
        docker_image: Docker image name
        timeout: Test timeout in seconds
        test_patch_file: Optional path to golden test patch file (overrides trajectory)
        csv_f2p_file: Optional path to CSV-extracted F2P tests file (class-level F2P from CSV)
    """
    
    container_name = f"velora3_eval_{int(time.time())}"
    
    try:
        # Load trajectory
        logger.info(f"Loading trajectory from {trajectory_file}")
        with open(trajectory_file, 'r') as f:
            trajectory = json.loads(f.readline())
        
        # Load F2P data from primary file
        logger.info(f"Loading F2P tests for instance {velora_instance_id}")
        f2p_data = load_extracted_f2p(f2p_file, velora_instance_id)
        
        # If CSV F2P file provided, load class-level F2P tests
        csv_f2p_data = {}
        if csv_f2p_file:
            logger.info(f"Loading CSV F2P tests from {csv_f2p_file}")
            with open(csv_f2p_file, 'r') as f:
                for line in f:
                    if line.strip():
                        data = json.loads(line)
                        if data.get('instance_id') == velora_instance_id:
                            csv_f2p_data = data
                            break
        
        if not f2p_data:
            raise ValueError(f"No F2P data found for instance {velora_instance_id}")
        
        job_name = f2p_data.get('job_name', 'unknown')
        
        # Inject F2P into trajectory
        trajectory = inject_f2p_into_trajectory(trajectory, f2p_data)
        instance = trajectory.get('instance', {})
        
        instance_id = trajectory.get('instance_id', 'unknown')
        model_patch = extract_model_patch(trajectory)
        
        # Get test configuration
        fail_to_pass = instance.get('FAIL_TO_PASS', [])
        pass_to_pass = instance.get('PASS_TO_PASS', [])
        test_command = instance.get('test_command', 'make test')
        test_output_parser = instance.get('test_output_parser', 'generic/parse_log_make')
        language = instance.get('language', 'unknown')
        
        # Get test_patch - prefer external file over trajectory embedded
        if test_patch_file:
            logger.info(f"Loading test patch from file: {test_patch_file}")
            with open(test_patch_file, 'r') as f:
                test_patch = f.read()
        else:
            test_patch = instance.get('test_patch', '')
        
        # Check if test_patch is a URL (Google Drive) - if so, skip it
        if test_patch and ('drive.google.com' in test_patch or 'docs.google.com' in test_patch or test_patch.strip().startswith('[')):
            logger.warning(f"test_patch is a URL, not a patch. Use --test-patch-file to provide the actual patch.")
            test_patch = ''
        
        # Ensure test patch ends with newline (required by git apply)
        if test_patch and not test_patch.endswith('\n'):
            test_patch = test_patch + '\n'
        
        # Use CSV F2P if available (class-level F2P tests)
        if csv_f2p_data:
            fail_to_pass = csv_f2p_data.get('f2p_tests', fail_to_pass)
            pass_to_pass = csv_f2p_data.get('p2p_tests', pass_to_pass)
            logger.info(f"Using CSV F2P tests: {len(fail_to_pass)} F2P, {len(pass_to_pass)} P2P")
        
        logger.info(f"Instance ID: {instance_id}")
        logger.info(f"Job Name: {job_name}")
        logger.info(f"Language: {language}")
        logger.info(f"F2P tests: {len(fail_to_pass)}")
        logger.info(f"P2P tests: {len(pass_to_pass)}")
        logger.info(f"Test command: {test_command[:80]}...")
        logger.info(f"Parser: {test_output_parser}")
        
        # Start container
        logger.info(f"Starting container from {docker_image}")
        if not start_container(docker_image, container_name):
            return EvalReport(
                instance_id=instance_id,
                velora_instance_id=velora_instance_id,
                job_name=job_name,
                language=language,
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
        
        # Detect repo path in container
        _, repo_detect_out, _ = run_docker_command(
            container_name,
            "find /workspace /app /testbed -maxdepth 2 -name '.git' 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo '/workspace'"
        )
        repo_path = repo_detect_out.strip() or "/workspace"
        if not repo_path or repo_path == "/workspace":
            # Try to find any git repo
            _, repo_detect_out, _ = run_docker_command(
                container_name,
                "find / -maxdepth 4 -name '.git' -type d 2>/dev/null | head -1 | xargs dirname 2>/dev/null"
            )
            repo_path = repo_detect_out.strip() or "/workspace"
        logger.info(f"Detected repo path: {repo_path}")
        
        # === PILOT 2 FIX: Source environment and unset broken proxies ===
        env_setup = (
            "source /saved/ENV 2>/dev/null || source /saved/*/ENV 2>/dev/null || true; "
            "unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ftp_proxy FTP_PROXY all_proxy ALL_PROXY; "
            "export http_proxy='' https_proxy='' HTTP_PROXY='' HTTPS_PROXY=''; "
        )
        run_docker_command(container_name, env_setup)
        logger.info("Environment sourced and proxies cleared")
        
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
            
            # Try strict apply first, then fall back to --reject mode
            run_docker_command(
                container_name,
                f"cd {repo_path} && git apply -v /tmp/model.patch 2>&1 || "
                f"git apply --reject --whitespace=fix /tmp/model.patch 2>&1 || "
                "patch --batch --fuzz=5 -p1 -i /tmp/model.patch 2>&1 || true"
            )
        
        # === PILOT 2 FIX: Reset test files to clean state ===
        # ONLY reset test files if we have a golden test_patch to apply
        # If no test_patch, model's test files are part of the legitimate implementation
        if test_patch:
            logger.info("Resetting test files to clean state (golden test patch will be applied)...")
            
            # Get language-specific test file patterns
            if language == 'python':
                test_patterns = "'**/test*.py' '**/tests/' '**/*_test.py'"
            elif language == 'java':
                test_patterns = "'**/test/' '**/tests/' '**/*Test.java' '**/*IT.java'"
            elif language == 'rust':
                test_patterns = "'**/tests/' '**/*_test.rs'"
            elif language == 'go':
                test_patterns = "'**/*_test.go'"
            elif language in ['c', 'cpp']:
                test_patterns = "'**/test/' '**/tests/' '**/*_test.c' '**/*_test.cpp'"
            else:
                test_patterns = "'**/test*' '**/tests/'"
            
            # Remove NEW test files created by the model (git clean)
            run_docker_command(
                container_name,
                f"cd {repo_path} && git clean -fd {test_patterns} 2>/dev/null || true"
            )
            
            # Restore MODIFIED test files to original state (git checkout)
            run_docker_command(
                container_name,
                f"cd {repo_path} && git checkout -- {test_patterns} 2>/dev/null || true"
            )
            logger.info("Test files reset complete")
        else:
            logger.info("No golden test patch - keeping model's test files")
        
        # Apply test patch if present
        if test_patch:
            logger.info("Applying test patch...")
            with tempfile.NamedTemporaryFile(mode='w', suffix='.diff', delete=False) as f:
                f.write(test_patch)
                patch_file = f.name
            
            subprocess.run(
                ["docker", "cp", patch_file, f"{container_name}:/tmp/test.patch"],
                capture_output=True, timeout=30
            )
            os.unlink(patch_file)
            
            run_docker_command(
                container_name,
                f"cd {repo_path} && git apply -v /tmp/test.patch 2>&1 || true"
            )
        
        # For Java projects, fix formatting issues and skip spotless check
        if language == 'java' and 'mvn' in test_command:
            logger.info("Running mvn spotless:apply and skipping spotless:check...")
            # Run spotless:apply to fix formatting
            run_docker_command(
                container_name,
                f"cd {repo_path} && mvn spotless:apply -B 2>&1 || true",
                timeout=180
            )
            # Add skip flags to test command to avoid spotless:check failing the build
            if '-Dspotless.check.skip' not in test_command:
                test_command = test_command + ' -Dspotless.check.skip=true -Denforcer.skip=true'
        
        # For Go projects, run go mod tidy to resolve dependencies
        go_mod_output = ""
        if language == 'go' or 'go test' in test_command:
            logger.info("Running go mod tidy to resolve dependencies...")
            returncode, stdout, stderr = run_docker_command(
                container_name,
                f"cd {repo_path} && go mod tidy 2>&1",
                timeout=300
            )
            go_mod_output = stdout + stderr
            logger.info(f"go mod tidy result: returncode={returncode}")
            if returncode != 0:
                logger.warning(f"go mod tidy failed: {go_mod_output[-500:]}")
        
        # Run tests with environment setup and proxy clearing
        logger.info(f"Running test command: {test_command}")
        
        # Build full command with env setup (matching Pilot 2)
        full_test_cmd = (
            f"source /saved/ENV 2>/dev/null || source /saved/*/ENV 2>/dev/null || true; "
            f"unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; "
            f"export http_proxy='' https_proxy=''; "
            f"cd {repo_path} && {test_command} 2>&1"
        )
        
        returncode, stdout, stderr = run_docker_command(
            container_name,
            full_test_cmd,
            timeout=timeout
        )
        
        # Include go mod tidy output if available (for Go projects)
        full_output = ""
        if go_mod_output:
            full_output = f"=== GO MOD TIDY OUTPUT ===\n{go_mod_output}\n\n=== TEST OUTPUT ===\n"
        full_output += stdout + stderr
        
        # Parse results
        parser = get_parser(test_output_parser)
        test_status_map = parser(full_output)
        logger.info(f"Parsed {len(test_status_map)} test results")
        
        # Grade
        grade_results = grade_test_results(test_status_map, fail_to_pass, pass_to_pass)
        
        # Determine resolved
        all_f2p_pass = (len(grade_results['fail_to_pass_failed']) == 0 and 
                       len(grade_results['fail_to_pass_success']) > 0)
        all_p2p_pass = len(grade_results['pass_to_pass_failed']) == 0
        resolved = all_f2p_pass and all_p2p_pass
        
        return EvalReport(
            instance_id=instance_id,
            velora_instance_id=velora_instance_id,
            job_name=job_name,
            language=language,
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
            test_output=full_output[-200000:]  # Keep last 200KB to capture test output
        )
        
    except Exception as e:
        logger.error(f"Evaluation failed: {e}")
        import traceback
        traceback.print_exc()
        return EvalReport(
            instance_id='unknown',
            velora_instance_id=velora_instance_id,
            job_name='unknown',
            language='unknown',
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


# ============================================================================
# SWE-LANCER SPECIFIC EVALUATION
# ============================================================================

# Environment variables for SWE-Lancer monolith mode
USE_MONOLITH_IMAGE = os.environ.get('USE_MONOLITH_IMAGE', 'false').lower() == 'true'
MONOLITH_IMAGE = os.environ.get('MONOLITH_IMAGE', 'swelancer/swelancer_x86_monolith:releasev1')


def start_swelancer_container(docker_image: str, container_name: str, platform: str = "linux/amd64") -> bool:
    """Start a SWE-Lancer Docker container with proper entrypoint."""
    try:
        subprocess.run(["docker", "rm", "-f", container_name], capture_output=True, timeout=30)
    except:
        pass
    
    try:
        # SWE-Lancer images need to run /app/tests/run.sh as entrypoint
        result = subprocess.run(
            ["docker", "run", "-d", "--name", container_name,
             "--platform", platform,
             "--entrypoint", "/bin/bash",
             docker_image, "-c", "/app/tests/run.sh"],
            capture_output=True, text=True, timeout=120
        )
        if result.returncode != 0:
            logger.error(f"Failed to start container: {result.stderr}")
            return False
        
        # Wait for setup to complete
        logger.info("Waiting for SWE-Lancer container setup to complete...")
        for _ in range(60):  # Wait up to 5 minutes
            time.sleep(5)
            returncode, stdout, _ = run_docker_command(container_name, "cat /setup_done.txt 2>/dev/null || echo 'waiting'")
            if 'done' in stdout.lower():
                logger.info("Container setup complete")
                return True
        
        logger.warning("Container setup timed out, proceeding anyway")
        return True
        
    except Exception as e:
        logger.error(f"Failed to start container: {e}")
        return False


def evaluate_swelancer_instance(
    trajectory_file: str,
    instance_id: str,
    docker_image: str,
    base_commit: str,
    fail_to_pass: List[str],
    pass_to_pass: List[str],
    timeout: int = 900,
    use_monolith: bool = False,
) -> EvalReport:
    """
    Evaluate a SWE-Lancer trajectory using the official grading method.
    
    SWE-Lancer grading is based on pytest exit code:
    - Exit code 0 = PASS
    - Exit code 1 = FAIL
    - Exit code >= 2 = ERROR
    
    Args:
        trajectory_file: Path to trajectory output.jsonl
        instance_id: SWE-Lancer instance ID (e.g., "12155_1")
        docker_image: Docker image name (or monolith image)
        base_commit: Git commit hash to checkout for this task
        fail_to_pass: List of F2P test names
        pass_to_pass: List of P2P test names  
        timeout: Test timeout in seconds
        use_monolith: If True, checkout base_commit at runtime
    """
    
    container_name = f"swelancer_eval_{instance_id}_{int(time.time())}"
    
    try:
        # Load trajectory
        logger.info(f"Loading trajectory from {trajectory_file}")
        with open(trajectory_file, 'r') as f:
            trajectory = json.loads(f.readline())
        
        model_patch = extract_model_patch(trajectory)
        
        if not model_patch:
            logger.warning("No model patch found in trajectory")
        
        logger.info(f"Instance ID: {instance_id}")
        logger.info(f"Base Commit: {base_commit[:12]}...")
        logger.info(f"F2P tests: {len(fail_to_pass)}")
        logger.info(f"Docker Image: {docker_image}")
        logger.info(f"Using Monolith: {use_monolith}")
        
        # Start container
        logger.info(f"Starting SWE-Lancer container...")
        if not start_swelancer_container(docker_image, container_name):
            return EvalReport(
                instance_id=instance_id,
                velora_instance_id=instance_id,
                job_name="swelancer",
                language="javascript",
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
        
        repo_path = "/app/repo"
        
        # If using monolith, checkout the correct base_commit
        if use_monolith and base_commit:
            logger.info(f"Monolith mode: Checking out base commit {base_commit[:12]}...")
            returncode, stdout, stderr = run_docker_command(
                container_name,
                f"cd {repo_path} && git fetch origin 2>/dev/null || true && "
                f"git checkout {base_commit} 2>&1 && "
                f"git reset --hard {base_commit} 2>&1",
                timeout=300
            )
            if returncode != 0:
                logger.warning(f"Checkout may have issues: {stderr}")
            else:
                logger.info(f"Successfully checked out {base_commit[:12]}")
        
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
            
            # Apply patch with fallbacks
            returncode, stdout, stderr = run_docker_command(
                container_name,
                f"cd {repo_path} && git apply -v /tmp/model.patch 2>&1 || "
                f"git apply --reject --whitespace=fix /tmp/model.patch 2>&1 || "
                "patch --batch --fuzz=5 -p1 -i /tmp/model.patch 2>&1 || true"
            )
            logger.info(f"Patch apply result: returncode={returncode}")
        
        # Create logs directory for this instance
        run_docker_command(
            container_name,
            f"mkdir -p /app/tests/logs/{instance_id}"
        )
        
        # Run tests using the official SWE-Lancer method (ansible-playbook)
        logger.info(f"Running SWE-Lancer tests for instance {instance_id}...")
        returncode, stdout, stderr = run_docker_command(
            container_name,
            f'export ISSUE_ID={instance_id} && '
            f'ansible-playbook -i "localhost," --connection=local /app/tests/run_tests.yml 2>&1',
            timeout=timeout
        )
        
        ansible_output = stdout + stderr
        logger.info(f"Ansible playbook completed with returncode={returncode}")
        
        # Get pytest exit code (the official grading method)
        _, exit_code_str, _ = run_docker_command(
            container_name,
            f"cat /app/tests/logs/{instance_id}/pytest_exit_code 2>/dev/null || echo '-1'"
        )
        
        try:
            pytest_exit = int(exit_code_str.strip().split('\n')[-1])
        except (ValueError, IndexError):
            pytest_exit = -1
        
        logger.info(f"Pytest exit code: {pytest_exit}")
        
        # Get pytest log for detailed output
        _, pytest_log, _ = run_docker_command(
            container_name,
            f"cat /app/tests/logs/{instance_id}/pytest.log 2>/dev/null || echo 'No pytest log'"
        )
        
        full_output = f"=== ANSIBLE OUTPUT ===\n{ansible_output}\n\n=== PYTEST LOG ===\n{pytest_log}\n\n=== PYTEST EXIT CODE ===\n{pytest_exit}"
        
        # Grade based on pytest exit code (official SWE-Lancer method)
        if pytest_exit == 0:
            # All tests passed
            resolved = True
            fail_to_pass_success = fail_to_pass.copy()
            fail_to_pass_failed = []
            tests_passed = len(fail_to_pass)
            tests_failed = 0
            tests_error = 0
        elif pytest_exit == 1:
            # Tests failed
            resolved = False
            fail_to_pass_success = []
            fail_to_pass_failed = fail_to_pass.copy()
            tests_passed = 0
            tests_failed = len(fail_to_pass)
            tests_error = 0
        else:
            # Error (exit code >= 2 or -1)
            resolved = False
            fail_to_pass_success = []
            fail_to_pass_failed = fail_to_pass.copy()
            tests_passed = 0
            tests_failed = 0
            tests_error = len(fail_to_pass)
        
        return EvalReport(
            instance_id=instance_id,
            velora_instance_id=instance_id,
            job_name="swelancer",
            language="javascript",
            resolved=resolved,
            failed_apply_patch=False,
            failed_apply_test_patch=False,
            error_eval=(pytest_exit >= 2 or pytest_exit == -1),
            test_timeout=False,
            tests_passed=tests_passed,
            tests_failed=tests_failed,
            tests_error=tests_error,
            fail_to_pass_success=fail_to_pass_success,
            fail_to_pass_failed=fail_to_pass_failed,
            pass_to_pass_success=pass_to_pass.copy() if resolved else [],
            pass_to_pass_failed=[] if resolved else pass_to_pass.copy(),
            test_output=full_output[-200000:],
            f2p_validation_notes=f"pytest_exit_code={pytest_exit}"
        )
        
    except Exception as e:
        logger.error(f"SWE-Lancer evaluation failed: {e}")
        import traceback
        traceback.print_exc()
        return EvalReport(
            instance_id=instance_id,
            velora_instance_id=instance_id,
            job_name="swelancer",
            language="javascript",
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
            error_message=str(e)
        )
    finally:
        stop_container(container_name)


# ============================================================================
# CLI
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Velora3 Multi-Language Evaluation Script"
    )
    parser.add_argument("--trajectory-file", required=True, help="Path to trajectory output.jsonl")
    parser.add_argument("--f2p-file", help="Path to extracted F2P tests JSONL (optional for SWE-Lancer)")
    parser.add_argument("--instance-id", required=True, help="Velora instance ID")
    parser.add_argument("--docker-image", required=True, help="Docker image name")
    parser.add_argument("--output-file", required=True, help="Output file for eval results")
    parser.add_argument("--timeout", type=int, default=900, help="Test timeout in seconds")
    parser.add_argument("--test-patch-file", help="Optional: Path to golden test patch file (overrides trajectory)")
    parser.add_argument("--csv-f2p-file", help="Optional: Path to CSV-extracted F2P tests file")
    # SWE-Lancer specific arguments
    parser.add_argument("--swelancer", action="store_true", help="Use SWE-Lancer evaluation mode")
    parser.add_argument("--base-commit", help="Base commit hash (required for SWE-Lancer monolith mode)")
    parser.add_argument("--use-monolith", action="store_true", help="Use monolith image with runtime base_commit checkout")
    parser.add_argument("--fail-to-pass", help="Comma-separated list of F2P test names (for SWE-Lancer)")
    parser.add_argument("--pass-to-pass", help="Comma-separated list of P2P test names (for SWE-Lancer)")
    
    args = parser.parse_args()
    
    # Check for SWE-Lancer mode
    if args.swelancer:
        logger.info("Running in SWE-Lancer evaluation mode")
        
        # Parse F2P and P2P test lists
        fail_to_pass = args.fail_to_pass.split(',') if args.fail_to_pass else []
        pass_to_pass = args.pass_to_pass.split(',') if args.pass_to_pass else []
        
        # Use monolith image if requested
        docker_image = args.docker_image
        if args.use_monolith:
            docker_image = os.environ.get('MONOLITH_IMAGE', 'swelancer/swelancer_x86_monolith:releasev1')
            logger.info(f"Using monolith image: {docker_image}")
        
        report = evaluate_swelancer_instance(
            trajectory_file=args.trajectory_file,
            instance_id=args.instance_id,
            docker_image=docker_image,
            base_commit=args.base_commit or "",
            fail_to_pass=fail_to_pass,
            pass_to_pass=pass_to_pass,
            timeout=args.timeout,
            use_monolith=args.use_monolith,
        )
    else:
        # Standard multi-language evaluation
        if not args.f2p_file:
            parser.error("--f2p-file is required for non-SWE-Lancer evaluation")
        
        report = evaluate_instance(
            trajectory_file=args.trajectory_file,
            f2p_file=args.f2p_file,
            velora_instance_id=args.instance_id,
            docker_image=args.docker_image,
            timeout=args.timeout,
            test_patch_file=args.test_patch_file,
            csv_f2p_file=args.csv_f2p_file
        )
    
    # Print summary
    logger.info("=" * 60)
    logger.info("EVALUATION RESULTS")
    logger.info("=" * 60)
    logger.info(f"Instance ID: {report.instance_id}")
    logger.info(f"Velora Instance ID: {report.velora_instance_id}")
    logger.info(f"Job Name: {report.job_name}")
    logger.info(f"Language: {report.language}")
    logger.info(f"RESOLVED: {'YES' if report.resolved else 'NO'}")
    logger.info(f"F2P Success: {len(report.fail_to_pass_success)}/{len(report.fail_to_pass_success) + len(report.fail_to_pass_failed)}")
    logger.info(f"P2P Success: {len(report.pass_to_pass_success)}/{len(report.pass_to_pass_success) + len(report.pass_to_pass_failed)}")
    
    if report.error_message:
        logger.info(f"Error: {report.error_message}")
    
    # Save results
    with open(args.output_file, 'w') as f:
        f.write(json.dumps(asdict(report), indent=2))
    
    logger.info(f"Results saved to: {args.output_file}")
    
    return 0 if report.resolved else 1


if __name__ == "__main__":
    exit(main())

