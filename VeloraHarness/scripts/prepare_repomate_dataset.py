#!/usr/bin/env python3
"""
Convert CSV dataset to JSONL format for trajectory generation
Extracts 75 samples from repomate dataset
"""

import json
import csv
import sys
from pathlib import Path

# Increase CSV field size limit for large fields
csv.field_size_limit(10**7)  # 10MB limit

def csv_to_jsonl(csv_path, output_path, num_samples=75):
    """
    Convert CSV to JSONL format for SWE-bench style evaluation

    Args:
        csv_path: Path to input CSV file
        output_path: Path to output JSONL file
        num_samples: Number of samples to extract (default: 75)
    """
    print(f"Converting CSV to JSONL...")
    print(f"Input: {csv_path}")
    print(f"Output: {output_path}")
    print(f"Samples: {num_samples}")

    samples_written = 0

    with open(csv_path, 'r', encoding='utf-8-sig') as csvfile, \
         open(output_path, 'w', encoding='utf-8') as jsonlfile:

        reader = csv.DictReader(csvfile)

        for row in reader:
            if samples_written >= num_samples:
                break

            # Convert CSV row to SWE-bench JSONL format
            jsonl_record = {
                "instance_id": row.get('issue_fbid', ''),
                "repo": row.get('repo_source_uri', '').replace('https://github.com/', '').replace('.git', ''),
                "base_commit": row.get('commit_hash', ''),
                "problem_statement": row.get('issue_statement', ''),
                "hints_text": "",
                "patch": [row.get('functional_patch', '')] if row.get('functional_patch') else [],
                "test_patch": [row.get('test_patch', '')] if row.get('test_patch') else [],
                "FAIL_TO_PASS": row.get('fail_to_pass_tests', '').split('","') if row.get('fail_to_pass_tests') else [],
                "PASS_TO_PASS": row.get('pass_to_pass_tests', '').split('","') if row.get('pass_to_pass_tests') else [],
                "test_command": row.get('test_command', ''),
                "language": row.get('language', ''),
                "test_framework": row.get('test_framework', ''),
                "image_storage_uri": row.get('image_storage_uri', ''),
                "image_fbid": row.get('image_fbid', ''),
                "pr_title": row.get('pr_title', ''),
                "pr_url": row.get('pr_url', ''),
                "test_output_parser": row.get('test_output_parser', '')
            }

            # Clean up FAIL_TO_PASS and PASS_TO_PASS arrays
            if jsonl_record['FAIL_TO_PASS']:
                jsonl_record['FAIL_TO_PASS'] = [
                    t.strip(' []"') for t in jsonl_record['FAIL_TO_PASS']
                    if t.strip(' []"')
                ]

            if jsonl_record['PASS_TO_PASS']:
                jsonl_record['PASS_TO_PASS'] = [
                    t.strip(' []"') for t in jsonl_record['PASS_TO_PASS']
                    if t.strip(' []"')
                ]

            # Write JSONL record
            jsonlfile.write(json.dumps(jsonl_record, ensure_ascii=False) + '\n')
            samples_written += 1

            if samples_written % 10 == 0:
                print(f"  Processed {samples_written} samples...")

    print(f"✓ Successfully converted {samples_written} samples to JSONL")
    return samples_written

if __name__ == "__main__":
    # Paths
    csv_path = "/home/ec2-user/VeloraTrajectories/repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv"
    output_path = "/home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness/data/repomate_75_samples.jsonl"

    # Allow command line override
    if len(sys.argv) > 1:
        num_samples = int(sys.argv[1])
    else:
        num_samples = 75

    # Create output directory if needed
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)

    # Convert
    count = csv_to_jsonl(csv_path, output_path, num_samples)

    print(f"\nDataset ready at: {output_path}")
    print(f"Total samples: {count}")
