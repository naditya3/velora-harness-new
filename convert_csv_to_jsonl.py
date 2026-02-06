#!/usr/bin/env python3
"""
Convert Repomate CSV files to VeloraHarness JSONL format

Usage:
    python convert_csv_to_jsonl.py \
        --csv "repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv" \
        --output data/tasks.jsonl \
        --limit 100
"""

import argparse
import csv
import json
import io
import os
import sys
from typing import Any, Dict, List, Optional

# Increase CSV field size limit to handle large fields (patches, descriptions)
csv.field_size_limit(sys.maxsize)

# Load image mapping from internal registry to ECR
def load_image_mapping(mapping_file: str = 'image_mapping.csv') -> Dict[str, str]:
    """Load image URI mapping from CSV"""
    mapping = {}
    if not os.path.exists(mapping_file):
        print(f"Warning: Image mapping file {mapping_file} not found. Using internal URIs.", file=sys.stderr)
        return mapping

    with open(mapping_file, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            internal_uri = row.get('internal_uri', '')
            ecr_uri = row.get('ecr_uri', '')
            if internal_uri and ecr_uri:
                mapping[internal_uri] = ecr_uri

    print(f"Loaded {len(mapping)} image URI mappings", file=sys.stderr)
    return mapping


def parse_test_list(test_str: str) -> List[str]:
    """Parse test list from CSV string format"""
    if not test_str or test_str == '[]':
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

    # Format: vmvm-registry.fbinfra.net/repomate_image_activ_go_test/meroxa_cli:hash
    parts = uri.split("/")
    if len(parts) >= 3:
        repo = parts[-1].split(":")[0]
        # Convert underscore to slash for org/repo format
        if "_" in repo:
            repo = repo.replace("_", "/", 1)
        return repo
    return ""


def csv_row_to_jsonl(row: Dict[str, Any], image_mapping: Optional[Dict[str, str]] = None) -> Dict[str, Any]:
    """Convert a single CSV row to JSONL format for VeloraHarness"""

    # Parse FAIL_TO_PASS tests
    f2p_str = row.get('fail_to_pass_tests', row.get('f2p', ''))
    f2p_tests = parse_test_list(f2p_str)

    # Parse PASS_TO_PASS tests
    p2p_str = row.get('pass_to_pass_tests', row.get('p2p', ''))
    p2p_tests = parse_test_list(p2p_str)

    # Extract repo
    repo = extract_repo_from_uri(row.get('image_storage_uri', ''))
    if not repo and 'repo_source_uri' in row:
        # Extract from git URI: https://github.com/owner/repo.git
        git_uri = row['repo_source_uri']
        if 'github.com/' in git_uri:
            repo = git_uri.split('github.com/')[-1].replace('.git', '')

    # Build JSONL entry
    dataset = {
        "instance_id": str(row.get('issue_fbid', row.get('instance_id', ''))),
        "repo": repo,
        "base_commit": row.get('commit_hash', ''),
        "problem_statement": row.get('issue_statement', ''),
        "hints_text": "",
        "language": row.get('language', 'unknown'),
        "test_framework": row.get('test_framework', ''),
        "version": "1.0",

        # Test information
        "FAIL_TO_PASS": f2p_tests,
        "PASS_TO_PASS": p2p_tests,
        "test_command": row.get('test_command', ''),
        "test_output_parser": row.get('test_output_parser', ''),

        # Docker image (map internal URI to ECR if available)
        "image_storage_uri": (
            image_mapping.get(row.get('image_storage_uri', ''), row.get('image_storage_uri', ''))
            if image_mapping else row.get('image_storage_uri', '')
        ),

        # Additional metadata
        "pr_title": row.get('pr_title', ''),
        "pr_description": row.get('pr_description', ''),
        "pr_url": row.get('pr_url', ''),
        "creation_timestamp": row.get('creation_timestamp', ''),

        # Patches (for evaluation)
        "test_patch": row.get('test_patch', ''),
        "functional_patch": row.get('functional_patch', ''),
    }

    return dataset


def convert_csv_to_jsonl(
    csv_path: str,
    output_path: str,
    limit: Optional[int] = None,
    instance_id: Optional[str] = None,
    language_filter: Optional[str] = None
) -> int:
    """
    Convert CSV file to JSONL format.

    Args:
        csv_path: Path to input CSV file
        output_path: Path to output JSONL file
        limit: Maximum number of instances to convert
        instance_id: Optional specific instance ID to extract
        language_filter: Optional language filter (e.g., 'go', 'python')

    Returns:
        Number of instances converted
    """
    print(f"Reading CSV file: {csv_path}")

    # Load image mapping
    image_mapping = load_image_mapping()

    # Read CSV with null byte handling
    with open(csv_path, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read().replace('\x00', '')

    reader = csv.DictReader(io.StringIO(content))
    rows = list(reader)

    print(f"Total rows in CSV: {len(rows)}")

    count = 0
    os.makedirs(os.path.dirname(output_path) or '.', exist_ok=True)

    with open(output_path, 'w') as out_f:
        for row in rows:
            # Apply filters
            if instance_id and str(row.get('issue_fbid', '')) != instance_id:
                continue

            if language_filter and row.get('language', '').lower() != language_filter.lower():
                continue

            # Apply limit
            if limit and count >= limit:
                break

            try:
                jsonl_entry = csv_row_to_jsonl(row, image_mapping)
                out_f.write(json.dumps(jsonl_entry) + '\n')
                count += 1

                if count % 1000 == 0:
                    print(f"Converted {count} instances...")

            except Exception as e:
                print(f"Warning: Skipping row due to error: {e}")
                continue

    return count


def main():
    parser = argparse.ArgumentParser(
        description='Convert Repomate CSV to VeloraHarness JSONL format'
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
        help='Maximum number of instances to convert'
    )
    parser.add_argument(
        '--instance-id', '-i',
        help='Extract only specific instance ID'
    )
    parser.add_argument(
        '--language',
        help='Filter by language (e.g., go, python, java, rust, cpp)'
    )

    args = parser.parse_args()

    if not os.path.exists(args.csv):
        print(f"Error: CSV file not found: {args.csv}")
        return 1

    count = convert_csv_to_jsonl(
        args.csv,
        args.output,
        limit=args.limit,
        instance_id=args.instance_id,
        language_filter=args.language
    )

    print(f"\n✓ Converted {count} instances to {args.output}")
    return 0


if __name__ == '__main__':
    exit(main())
