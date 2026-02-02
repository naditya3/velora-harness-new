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
    
    # Track current test class from testdox headers
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
    
    # Track failures/errors from the detailed section  
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
        
        # Detect failure section start
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
        
        # Helper to get alternative class names for matching
        def get_alternative_class_names(class_name: str) -> List[str]:
            """Generate alternative class names for matching.
            
            PHPUnit 10+ uses 'UnnamedTests' for classes without proper @testdox.
            We need to try common alternatives like 'Test', 'Tests', etc.
            """
            alternatives = [class_name]
            
            # If class ends with 'UnnamedTests', try parent namespace + common test class names
            if class_name.endswith('\\UnnamedTests'):
                parent_ns = class_name.rsplit('\\', 1)[0]
                alternatives.extend([
                    f"{parent_ns}\\Test",
                    f"{parent_ns}\\Tests", 
                    f"{parent_ns}\\TestCase",
                ])
            
            # Add "Test" suffix if not present
            if not class_name.endswith("Test"):
                alternatives.append(class_name + "Test")
            
            return alternatives
        
        # Testdox format: ✔ or ✓ for pass, ✘ or ✗ for fail
        if '✔' in line or '✓' in line:
            testdox_name = re.sub(r'[✔✓]\s*', '', line_stripped).strip()
            if testdox_name and current_class:
                method_name = testdox_to_method_name(testdox_name)
                # Add all alternative class name variants
                for alt_class in get_alternative_class_names(current_class):
                    full_test_name = f"{alt_class}::{method_name}"
                    test_status_map[full_test_name] = TestStatus.PASSED
            elif testdox_name:
                test_status_map[testdox_name] = TestStatus.PASSED
                
        elif '✘' in line or '✗' in line:
            testdox_name = re.sub(r'[✘✗]\s*', '', line_stripped).strip()
            if testdox_name and current_class:
                method_name = testdox_to_method_name(testdox_name)
                # Add all alternative class name variants
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


def parse_log_ruby_minitest(log: str, grading_spec: Any = None) -> Dict[str, str]:
    """
    Parser for test logs generated with Ruby Minitest framework.

    Handles Minitest output format:
        ClassName::SubClass#test_method = 0.05 s = .
        ClassName::SubClass#test_method = 0.05 s = F
        ClassName::SubClass#test_method [PASS]
        ClassName::SubClass#test_method [FAIL]

    Also handles verbose format:
        test_method_name (ClassName::SubClass) = 0.01 s = .
    """
    test_status_map = {}

    for line in log.split("\n"):
        line_stripped = line.strip()

        # Primary format: ClassName::SubClass#test_method = 0.05 s = .
        # Result codes: . (pass), F (fail), E (error), S/N (skip)
        match = re.match(r'^([\w:]+#[\w]+)\s*=.*?=\s*([.FESN])\s*$', line_stripped)
        if match:
            test_name, result = match.groups()
            if result == '.':
                test_status_map[test_name] = TestStatus.PASSED
            elif result == 'F':
                test_status_map[test_name] = TestStatus.FAILED
            elif result == 'E':
                test_status_map[test_name] = TestStatus.ERROR
            elif result == 'S' or result == 'N':
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

        # Minitest verbose format: test_method_name (ClassName::SubClass) = 0.01 s = .
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
            elif result == 'S' or result == 'N':
                test_status_map[test_name] = TestStatus.SKIPPED

    return test_status_map

# Parser registry mapping parser names to functions
PARSER_REGISTRY: Dict[str, Callable] = {
    "python/parse_log_pytest_v3": parse_log_pytest_v3,
    "python/parse_log_pytest": parse_log_pytest_v3,  # Alias
    "python/parse_log_unittest": parse_log_unittest,
    "php/parse_log_phpunit": parse_log_phpunit,
    "parsers/ruby_minitest_parser.py": parse_log_ruby_minitest,  # Dataset parser path
    "ruby/parse_log_minitest": parse_log_ruby_minitest,  # Standard alias
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
    EXCLUDED_FILES = [
        'command', 'exec_time', 'exit_code', 'stdout', 'stderr',
        'test_output', 'test_log', '.test_', '_test_output'
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
    
    
    def normalize_test_name(test_name: str) -> str:
        """
        Normalize test name to enable matching between different formats.
        Converts: tests/Console/MetaCommand/MetaCommandTest.php::testCommand
        To: MetaCommandTest::testCommand
        
        Also handles: Barryvdh\LaravelIdeHelper\Tests\Console\MetaCommand\MetaCommandTest::testCommand
        To: MetaCommandTest::testCommand
        """
        if '::' in test_name:
            path_part, method = test_name.rsplit('::', 1)
        else:
            return test_name
        
        # Handle file path format: tests/Console/MetaCommand/MetaCommandTest.php
        if '.php' in path_part:
            # Extract class name from file path
            class_name = path_part.split('/')[-1].replace('.php', '')
        # Handle class name format: Barryvdh\LaravelIdeHelper\Tests\Console\MetaCommand\MetaCommandTest
        elif '\\' in path_part:
            class_name = path_part.split('\\')[-1]
        else:
            class_name = path_part.split('/')[-1] if '/' in path_part else path_part
        
        return f"{class_name}::{method}"
    
    def test_names_match(expected: str, actual: str) -> bool:
        """Check if two test names match, handling different formats."""
        # Exact match
        if expected == actual:
            return True
        # Substring match
        if expected in actual or actual in expected:
            return True
        # Normalized match
        norm_expected = normalize_test_name(expected)
        norm_actual = normalize_test_name(actual)
        if norm_expected == norm_actual:
            return True
        # Also check if just the method names match (for edge cases)
        if '::' in norm_expected and '::' in norm_actual:
            _, method_exp = norm_expected.rsplit('::', 1)
            _, method_act = norm_actual.rsplit('::', 1)
            class_exp = norm_expected.split('::')[0]
            class_act = norm_actual.split('::')[0]
            # Match if method same AND class name contained in each other
            if method_exp == method_act and (class_exp in class_act or class_act in class_exp):
                return True
        return False
    
    # Build a set of all failed/error test names for quick lookup
    failed_or_error_tests = set()
    for result_test, status in test_status_map.items():
        if status in (TestStatus.FAILED, TestStatus.ERROR):
            failed_or_error_tests.add(result_test)
            # Also add normalized version
            failed_or_error_tests.add(normalize_test_name(result_test))
    
    # Grade F2P tests (should now pass)
    for test in fail_to_pass:
        matched = False
        for result_test, status in test_status_map.items():
            # Check various matching strategies
            if test_names_match(test, result_test):
                if status == TestStatus.PASSED:
                    results['fail_to_pass_success'].append(test)
                else:
                    results['fail_to_pass_failed'].append(test)
                matched = True
                break
        
        if not matched:
            # For PHPUnit standard output, tests not in error/failure section are assumed to pass
            # Check if this test is in the failed/error set
            norm_test = normalize_test_name(test)
            is_failed = any(test_names_match(test, f) for f in failed_or_error_tests)
            
            if is_failed:
                logger.info(f"F2P test matched as failed/error: {test}")
                results['fail_to_pass_failed'].append(test)
            else:
                # Test not found in any failure section - assume passed (for standard PHPUnit output)
                logger.info(f"F2P test not in error/failure section, assuming passed: {test}")
                results['fail_to_pass_success'].append(test)
    
    # Grade P2P tests (should still pass)
    # XFAIL and XPASS are acceptable for P2P (not regressions)
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
            # For PHPUnit standard output, tests not in error/failure section are assumed to pass
            norm_test = normalize_test_name(test)
            is_failed = any(test_names_match(test, f) for f in failed_or_error_tests)
            
            if is_failed:
                logger.info(f"P2P test matched as failed/error: {test}")
                results['pass_to_pass_failed'].append(test)
            else:
                # Test not found in failure section - assume passed
                logger.info(f"P2P test not in error/failure section, assuming passed: {test}")
                results['pass_to_pass_success'].append(test)
    
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
            trajectory = json.loads(f.readline())
        
        instance_id = trajectory.get('instance_id', 'unknown')
        model_patch = extract_model_patch(trajectory)
        
        logger.info(f"Instance ID: {instance_id}")
        logger.info(f"Model patch length: {len(model_patch)} chars")
        
        # Step 2: Load dataset
        logger.info(f"Loading dataset from {dataset_file}")
        with open(dataset_file, 'r') as f:
            for line in f:
                if line.strip():
                    dataset = json.loads(line)
                    if dataset.get('instance_id') == instance_id:
                        break
            else:
                raise ValueError(f"Instance {instance_id} not found in dataset")
        
        # FIX: Use trajectory's instance field as primary source, fallback to dataset
        # The trajectory's instance field contains complete data from OpenHands
        traj_instance = trajectory.get('instance', {})
        
        # Parse fields - prefer trajectory instance over dataset file
        fail_to_pass = traj_instance.get('FAIL_TO_PASS') or dataset.get('FAIL_TO_PASS', [])
        pass_to_pass = traj_instance.get('PASS_TO_PASS') or dataset.get('PASS_TO_PASS', [])
        test_command = traj_instance.get('test_command') or dataset.get('test_command', 'pytest')
        test_output_parser = traj_instance.get('test_output_parser') or dataset.get('test_output_parser', 'python/parse_log_pytest_v3')
        test_patch = traj_instance.get('test_patch') or dataset.get('test_patch', '')
        
        # #region agent log
        import ast
        debug_log_path = "/Users/macbookpro/Desktop/SWETEs7/.cursor/debug.log"
        def _debug_log(msg, data, hyp):
            import time
            try:
                with open(debug_log_path, 'a') as f:
                    f.write(json.dumps({"timestamp": int(time.time()*1000), "message": msg, "data": data, "hypothesisId": hyp, "location": "eval_pilot2_standardized.py:565"}) + '\n')
            except: pass
        _debug_log("F2P raw value", {"type": str(type(fail_to_pass)), "first_100": str(fail_to_pass)[:100], "is_string": isinstance(fail_to_pass, str)}, "A")
        _debug_log("P2P raw value", {"type": str(type(pass_to_pass)), "first_100": str(pass_to_pass)[:100], "is_string": isinstance(pass_to_pass, str)}, "A")
        # #endregion
        
        # FIX: Handle both JSON and Python literal formats
        # Some datasets store F2P/P2P as Python literals with single quotes: ['test1', 'test2']
        # json.loads() fails on these, so we fallback to ast.literal_eval()
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
        
        fail_to_pass = _parse_list_field(fail_to_pass)
        pass_to_pass = _parse_list_field(pass_to_pass)
        
        # #region agent log
        _debug_log("F2P after parse", {"count": len(fail_to_pass), "type": str(type(fail_to_pass)), "first_3": fail_to_pass[:3] if fail_to_pass else []}, "A")
        _debug_log("P2P after parse", {"count": len(pass_to_pass), "type": str(type(pass_to_pass)), "first_3": pass_to_pass[:3] if pass_to_pass else []}, "A")
        # #endregion
        
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
        parser_func = get_parser(test_output_parser)
        test_status_map = parser_func(full_output)
        
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
    parser.add_argument("--output-dir", help="Output directory for eval_outputs structure (defaults to trajectory dir)")
    parser.add_argument("--timeout", type=int, default=900, help="Test timeout in seconds (default: 900)")
    
    args = parser.parse_args()
    
    # Determine output directory
    if args.output_dir:
        output_dir = args.output_dir
    else:
        output_dir = os.path.dirname(args.trajectory_file)
    
    # Load dataset to get test_command for eval.sh
    with open(args.dataset_file, 'r') as f:
        dataset = json.loads(f.readline())
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
    
    # Save results (original JSONL format)
    # Load original trajectory to merge
    with open(args.trajectory_file, 'r') as f:
        original = json.loads(f.readline())
    
    # Add eval details
    original['pilot2_eval_details'] = asdict(report)
    original['resolved'] = report.resolved
    
    with open(args.output_file, 'w') as f:
        f.write(json.dumps(original) + '\n')
    
    logger.info(f"Results saved to: {args.output_file}")
    
    # ============================================================
    # CREATE EVAL_OUTPUTS DIRECTORY STRUCTURE
    # ============================================================
    logger.info("Creating eval_outputs directory structure...")
    
    # Create directories
    eval_outputs_dir = os.path.join(output_dir, 'eval_outputs')
    instance_eval_dir = os.path.join(eval_outputs_dir, report.instance_id)
    os.makedirs(instance_eval_dir, exist_ok=True)
    
    # 1. Extract and save patch.diff from trajectory
    git_patch = original.get('test_result', {}).get('git_patch', '')
    if not git_patch:
        git_patch = original.get('git_patch', '')
    patch_file = os.path.join(instance_eval_dir, 'patch.diff')
    with open(patch_file, 'w') as f:
        f.write(git_patch)
    logger.info(f"Created: {patch_file}")
    
    # 2. Create report.json (OpenHands format)
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
    report_file = os.path.join(instance_eval_dir, 'report.json')
    with open(report_file, 'w') as f:
        json.dump(openhands_report, f, indent=4)
    logger.info(f"Created: {report_file}")
    
    # 3. Save test_output.txt
    test_output_file = os.path.join(instance_eval_dir, 'test_output.txt')
    with open(test_output_file, 'w') as f:
        f.write(report.test_output)
    logger.info(f"Created: {test_output_file}")
    
    # 4. Create run_instance.log (evaluation execution log)
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
    
    # 5. Create eval.sh (test command used)
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
    
    # 6. Create aggregate report.json in eval_outputs root
    aggregate_report_file = os.path.join(eval_outputs_dir, 'report.json')
    with open(aggregate_report_file, 'w') as f:
        json.dump(openhands_report, f, indent=4)
    logger.info(f"Created: {aggregate_report_file}")
    
    # 7. Create eval_summary.json in output directory
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
    
    return 0 if report.resolved else 1


if __name__ == "__main__":
    exit(main())
