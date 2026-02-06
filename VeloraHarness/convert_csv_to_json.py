#!/usr/bin/env python3
"""
Convert CSV to JSONL format for trajectory generation.
Extracts the first 100 tasks from the CSV file.
"""

import csv
import json
import sys
from pathlib import Path

# Increase CSV field size limit to handle large fields
csv.field_size_limit(10 * 1024 * 1024)  # 10MB per field


def convert_csv_to_jsonl(csv_path: str, output_path: str, num_tasks: int = 100):
    """
    Convert CSV file to JSONL format.

    Args:
        csv_path: Path to input CSV file
        output_path: Path to output JSONL file
        num_tasks: Number of tasks to extract (default: 100)
    """
    print(f"Converting CSV to JSONL...")
    print(f"Input: {csv_path}")
    print(f"Output: {output_path}")
    print(f"Number of tasks: {num_tasks}")

    tasks_written = 0

    with open(csv_path, 'r', encoding='utf-8-sig') as csv_file:
        # Use csv.DictReader to handle CSV parsing
        reader = csv.DictReader(csv_file)

        with open(output_path, 'w', encoding='utf-8') as jsonl_file:
            for idx, row in enumerate(reader, start=1):
                if tasks_written >= num_tasks:
                    break

                # Create a JSON object with instance_id
                # Use issue_fbid as the instance_id
                json_obj = {
                    "instance_id": f"task_{idx:03d}_{row['issue_fbid']}",
                    "task_number": idx,
                    **row  # Include all CSV columns
                }

                # Write as JSONL (one JSON object per line)
                jsonl_file.write(json.dumps(json_obj, ensure_ascii=False) + '\n')
                tasks_written += 1

                if tasks_written % 10 == 0:
                    print(f"  Processed {tasks_written}/{num_tasks} tasks...")

    print(f"\n✓ Successfully converted {tasks_written} tasks")
    print(f"✓ Output saved to: {output_path}")
    return tasks_written


def main():
    # Paths
    base_dir = Path("/home/ec2-user/VeloraTrajectories")
    csv_path = base_dir / "repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv"
    output_dir = base_dir / "jaeger" / "VeloraHarness" / "data"
    output_dir.mkdir(parents=True, exist_ok=True)

    # Default to 100 tasks, but allow command-line override
    num_tasks = 100
    if len(sys.argv) > 1:
        try:
            num_tasks = int(sys.argv[1])
            if num_tasks < 1 or num_tasks > 1000:
                print(f"Error: Number of tasks must be between 1 and 1000")
                sys.exit(1)
        except ValueError:
            print(f"Error: Invalid number '{sys.argv[1]}'")
            sys.exit(1)

    output_path = output_dir / f"repomate_{num_tasks}_tasks.jsonl"

    # Check if input file exists
    if not csv_path.exists():
        print(f"Error: CSV file not found at {csv_path}")
        sys.exit(1)

    # Convert
    try:
        convert_csv_to_jsonl(str(csv_path), str(output_path), num_tasks)
    except Exception as e:
        print(f"\nError during conversion: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
