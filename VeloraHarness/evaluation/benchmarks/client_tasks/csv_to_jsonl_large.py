#!/usr/bin/env python3
"""
CSV to JSONL Converter for Client Tasks - Handles Large Fields

Converts client CSV format to OpenHands-compatible JSONL format with large field support.

Usage:
    python csv_to_jsonl_large.py --csv input.csv --output output.jsonl --limit N
"""

import argparse
import csv
import json
import io
import os
import sys
from typing import Any, Dict, List, Optional

# Increase CSV field size limit
csv.field_size_limit(sys.maxsize)


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
            # Handle format like: repomate_image_activ_go_test/meroxa_cli
            if repo.count("_") >= 2:
                # Split on last underscore to get potential repo name
                parts = repo.rsplit("_", 1)
                repo = parts[-1] if len(parts) > 1 else repo
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

    # Extract repo from image URI or use repo_source_uri
    repo = row.get('repo_source_uri', '')
    if repo and 'github.com' in repo:
        # Extract from https://github.com/owner/repo.git
        repo = repo.replace('https://github.com/', '').replace('.git', '')

    if not repo:
        repo = extract_repo_from_uri(row.get('image_storage_uri', ''))

    # Get instance ID
    instance_id = str(row.get('issue_fbid', ''))

    # Build problem statement
    problem_statement = row.get('issue_statement', '')
    if not problem_statement:
        problem_statement = row.get('pr_description', row.get('pr_title', ''))

    # Get language and test framework
    language = row.get('language', '')
    test_framework = row.get('test_framework', '')

    # Build dataset entry
    dataset = {
        "instance_id": instance_id,
        "repo": repo,
        "base_commit": row.get('commit_hash', ''),
        "problem_statement": problem_statement,
        "hints_text": "",
        "language": language,
        "test_framework": test_framework,
        "version": "1.0",
        "FAIL_TO_PASS": f2p_tests,
        "PASS_TO_PASS": p2p_tests,
        "environment_setup_commit": row.get('commit_hash', ''),
        # Client-specific fields
        "test_command": row.get('test_command', ''),
        "test_output_parser": row.get('test_output_parser', ''),
        "test_patch": row.get('test_patch', ''),
        "image_storage_uri": row.get('image_storage_uri', ''),
        "fail_to_pass_tests": row.get('fail_to_pass_tests', ''),
        "pass_to_pass_tests": row.get('pass_to_pass_tests', ''),
    }

    return dataset


def convert_csv_to_jsonl(
    csv_path: str,
    output_path: str,
    limit: Optional[int] = None,
    skip: int = 0
) -> int:
    """
    Convert CSV file to JSONL format.

    Args:
        csv_path: Path to input CSV file
        output_path: Path to output JSONL file
        limit: Optional limit on number of instances to convert
        skip: Number of instances to skip from beginning

    Returns:
        Number of instances converted
    """
    # Read CSV with null byte handling
    with open(csv_path, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read().replace('\x00', '')

    reader = csv.DictReader(io.StringIO(content))

    count = 0
    skipped = 0
    with open(output_path, 'w') as out_f:
        for row in reader:
            # Skip initial rows if requested
            if skipped < skip:
                skipped += 1
                continue

            # Check limit
            if limit and count >= limit:
                break

            try:
                jsonl_entry = csv_row_to_jsonl(row)
                out_f.write(json.dumps(jsonl_entry) + '\n')
                count += 1

                if count % 10 == 0:
                    print(f"Processed {count} instances...")

            except Exception as e:
                print(f"Warning: Skipping row {count + skipped} due to error: {e}")
                continue

    return count


def main():
    parser = argparse.ArgumentParser(
        description='Convert client CSV to OpenHands JSONL format (handles large fields)'
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
        '--limit', '-l',
        type=int,
        default=50,
        help='Maximum number of instances to convert (default: 50)'
    )
    parser.add_argument(
        '--skip', '-s',
        type=int,
        default=0,
        help='Number of instances to skip from beginning (default: 0)'
    )

    args = parser.parse_args()

    if not os.path.exists(args.csv):
        print(f"Error: CSV file not found: {args.csv}")
        return 1

    print(f"Converting CSV to JSONL...")
    print(f"Input: {args.csv}")
    print(f"Output: {args.output}")
    print(f"Limit: {args.limit} instances")
    print(f"Skip: {args.skip} instances")
    print()

    count = convert_csv_to_jsonl(args.csv, args.output, args.limit, args.skip)

    print()
    print(f"✓ Successfully converted {count} instances to {args.output}")
    return 0


if __name__ == '__main__':
    exit(main())
