#!/usr/bin/env python3
"""
CSV to JSONL Converter for Client Tasks

Converts client CSV format to OpenHands-compatible JSONL format.

Usage:
    python csv_to_jsonl.py --csv input.csv --output output.jsonl [--instance-id ID]

CSV Expected Columns:
    - instance_id: Unique task identifier
    - test_command: Command to run tests
    - test_output_parser: Parser to use (e.g., python/parse_log_pytest_v3)
    - test_patch: JSON array of patches to apply
    - fail_to_pass_tests: Tests that should pass after fix
    - pass_to_pass_tests: Tests that should remain passing
    - base_commit: Git commit to reset to
    - image_storage_uri: Docker image location
    - issue_statement: Problem description
"""

import argparse
import csv
import json
import io
import os
import re
from typing import Any, Dict, List, Optional


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


def extract_repo_from_uri(uri: str) -> str:
    """Extract repo name from image storage URI"""
    if not uri:
        return ""
    
    # Format: registry/namespace/repo:tag or registry/repo:tag
    parts = uri.split("/")
    if len(parts) >= 2:
        repo_tag = parts[-1]
        repo = repo_tag.split(":")[0]
        # Convert underscore format back to owner/repo
        if "_" in repo:
            repo = repo.replace("_", "/", 1)
        return repo
    return ""


def csv_row_to_jsonl(row: Dict[str, Any]) -> Dict[str, Any]:
    """
    Convert a single CSV row to JSONL format.
    
    Maps client CSV fields to OpenHands-compatible format.
    """
    # Parse test lists
    f2p_tests = parse_test_list(row.get('fail_to_pass_tests', ''))
    p2p_tests = parse_test_list(row.get('pass_to_pass_tests', ''))
    
    # Extract repo from image URI
    repo = extract_repo_from_uri(row.get('image_storage_uri', ''))
    if not repo:
        repo = row.get('repo', '')
    
    # Get instance ID
    instance_id = str(row.get('instance_id', ''))
    
    # Build problem statement
    problem_statement = row.get('issue_statement', '')
    if not problem_statement:
        problem_statement = row.get('pr_description', row.get('pr_title', ''))
    
    # Build dataset entry
    dataset = {
        "instance_id": instance_id,
        "repo": repo,
        "base_commit": row.get('base_commit', row.get('commit_hash', '')),
        "problem_statement": problem_statement,
        "hints_text": "",
        "created_at": row.get('creation_timestamp', ''),
        "version": "1.0",
        "FAIL_TO_PASS": f2p_tests,
        "PASS_TO_PASS": p2p_tests,
        "environment_setup_commit": row.get('base_commit', row.get('commit_hash', '')),
        # Client-specific fields
        "test_command": row.get('test_command', 'pytest --no-header -rA --tb=no'),
        "test_output_parser": row.get('test_output_parser', 'python/parse_log_pytest_v3'),
        "test_patch": row.get('test_patch', ''),
        "image_storage_uri": row.get('image_storage_uri', ''),
        "fail_to_pass_tests": row.get('fail_to_pass_tests', ''),
        "pass_to_pass_tests": row.get('pass_to_pass_tests', ''),
    }
    
    return dataset


def convert_csv_to_jsonl(
    csv_path: str,
    output_path: str,
    instance_id: Optional[str] = None
) -> int:
    """
    Convert CSV file to JSONL format.
    
    Args:
        csv_path: Path to input CSV file
        output_path: Path to output JSONL file
        instance_id: Optional specific instance ID to extract
    
    Returns:
        Number of instances converted
    """
    # Read CSV with null byte handling
    with open(csv_path, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read().replace('\x00', '')
    
    reader = csv.DictReader(io.StringIO(content))
    rows = list(reader)
    
    count = 0
    with open(output_path, 'w') as out_f:
        for row in rows:
            # Filter by instance_id if specified
            if instance_id and str(row.get('instance_id', '')) != instance_id:
                continue
            
            try:
                jsonl_entry = csv_row_to_jsonl(row)
                out_f.write(json.dumps(jsonl_entry) + '\n')
                count += 1
            except Exception as e:
                print(f"Warning: Skipping row due to error: {e}")
                continue
    
    return count


def main():
    parser = argparse.ArgumentParser(
        description='Convert client CSV to OpenHands JSONL format'
    )
    parser.add_argument(
        '--csv', '-c',
        required=True,
        help='Path to input CSV file'
    )
    parser.add_argument(
        '--output', '-o',
        required=True,
        help='Path to output JSONL file'
    )
    parser.add_argument(
        '--instance-id', '-i',
        help='Extract only specific instance ID'
    )
    
    args = parser.parse_args()
    
    if not os.path.exists(args.csv):
        print(f"Error: CSV file not found: {args.csv}")
        return 1
    
    count = convert_csv_to_jsonl(args.csv, args.output, args.instance_id)
    
    print(f"Converted {count} instances to {args.output}")
    return 0


if __name__ == '__main__':
    exit(main())

