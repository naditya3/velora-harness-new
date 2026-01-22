"""
Simplified version of client's log parsers for standalone use
Adapted from Harness/log_parsers.py
"""
import re
from enum import Enum


class TestStatus(Enum):
    """Test status values"""
    PASSED = "PASSED"
    FAILED = "FAILED"
    SKIPPED = "SKIPPED"
    ERROR = "ERROR"


def parse_log_pytest(log: str) -> dict[str, str]:
    """
    Parser for test logs generated with PyTest framework
    
    Args:
        log (str): log content
    Returns:
        dict: test case to test status mapping
    """
    test_status_map = {}
    for line in log.split("\n"):
        if any(line.startswith(x.value) for x in TestStatus):
            # Additional parsing for FAILED status
            if line.startswith(TestStatus.FAILED.value):
                line = line.replace(" - ", " ")
            test_case = line.split()
            if len(test_case) <= 1:
                continue
            test_status_map[test_case[1]] = TestStatus(test_case[0])
    return {
        test_name: test_status.value
        for test_name, test_status in test_status_map.items()
    }


def parse_log_pytest_v3(log: str) -> dict[str, str]:
    """
    Parser for test logs generated with PyTest framework (Repomate version)
    
    Args:
        log (str): log content
    Returns:
        dict: test case to test status mapping
    """
    test_status_map = {}
    escapes = "".join([chr(char) for char in range(1, 32)])
    translator = str.maketrans("", "", escapes)

    # Precompile the regex pattern for efficiency
    status_values = "|".join(x.value for x in TestStatus)
    status_pattern = re.compile(rf"^({status_values})\s+")

    for line in log.split("\n"):
        line = re.sub(r"\[(\d+)m", "", line)
        line = line.translate(translator)
        line = line.replace(" - ", " ")

        match = status_pattern.match(line)
        if match:
            test_case = line.split()
            if len(test_case) >= 2:
                status = test_case[0]
                test_name = test_case[1]
                test_status_map[test_name] = TestStatus(status)

        # Optional: still support older pytest output where status is at the end
        elif any(line.endswith(x.value) for x in TestStatus):
            test_case = line.split()
            if len(test_case) >= 2:
                test_status_map[test_case[0]] = TestStatus(test_case[1])

    return {
        test_name: test_status.value
        for test_name, test_status in test_status_map.items()
    }


def get_parser_for_name(parser_name: str):
    """Get the appropriate parser function based on name"""
    parsers = {
        "pytest": parse_log_pytest,
        "python/parse_log_pytest": parse_log_pytest,
        "python/parse_log_pytest_v3": parse_log_pytest_v3,
        "parse_log_pytest": parse_log_pytest,
        "parse_log_pytest_v3": parse_log_pytest_v3,
    }
    return parsers.get(parser_name, parse_log_pytest)

