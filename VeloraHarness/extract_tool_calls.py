#!/usr/bin/env python3
"""
Extract tool call counts from output.jsonl files and generate a CSV report.
"""

import json
import os
import re
import csv
from collections import Counter
from pathlib import Path

def extract_model(folder_name):
    """Extract model name (gemini/claude) from folder name."""
    folder_lower = folder_name.lower()
    if 'gemini' in folder_lower:
        return 'gemini'
    elif 'claude' in folder_lower:
        return 'claude'
    return 'unknown'

def extract_run_number(folder_name):
    """Extract run number from folder name (e.g., run0, run1, etc.)."""
    match = re.search(r'run(\d+)', folder_name)
    if match:
        return int(match.group(1))
    return -1

def extract_task_name(task_folder):
    """Extract task name from folder (remove _output suffix)."""
    return task_folder.replace('_output', '')

def process_output_jsonl(filepath):
    """Process an output.jsonl file and return action counts, token usage, and cost."""
    action_counts = Counter()
    total_input_tokens = 0
    total_output_tokens = 0
    accumulated_cost = 0.0
    try:
        with open(filepath, 'r') as f:
            for line in f:
                try:
                    data = json.loads(line.strip())
                    if 'history' in data:
                        for item in data['history']:
                            action = item.get('action')
                            if action:
                                action_counts[action] += 1
                    # Extract token usage and cost from metrics
                    if 'metrics' in data:
                        token_usage = data['metrics'].get('accumulated_token_usage', {})
                        total_input_tokens += token_usage.get('prompt_tokens', 0)
                        total_output_tokens += token_usage.get('completion_tokens', 0)
                        accumulated_cost += data['metrics'].get('accumulated_cost', 0.0)
                except json.JSONDecodeError:
                    continue
    except Exception as e:
        print(f"Error processing {filepath}: {e}")
    return action_counts, total_input_tokens, total_output_tokens, accumulated_cost

def process_run_folder(run_path, task_name, all_data, all_tools):
    """Process a run folder and add data to all_data list."""
    output_file = run_path / 'output.jsonl'
    if not output_file.exists():
        return

    run_folder = run_path.name
    model = extract_model(run_folder)
    run_num = extract_run_number(run_folder)

    # Process the output.jsonl file
    action_counts, input_tokens, output_tokens, cost = process_output_jsonl(output_file)

    # Track all tools seen
    all_tools.update(action_counts.keys())

    all_data.append({
        'task': task_name,
        'model': model,
        'run': run_num,
        'actions': action_counts,
        'total_input_tokens': input_tokens,
        'total_output_tokens': output_tokens,
        'accumulated_cost': cost
    })

def main():
    base_dir = Path('hi/jsonls')

    # Collect all data
    all_data = []
    all_tools = set()

    # Walk through the directory structure
    for task_folder in os.listdir(base_dir):
        task_path = base_dir / task_folder
        if not task_path.is_dir():
            continue

        task_name = extract_task_name(task_folder)

        # Look for subfolders in task directory
        for subfolder in os.listdir(task_path):
            subfolder_path = task_path / subfolder
            if not subfolder_path.is_dir():
                continue

            # Check if this subfolder contains output.jsonl directly (flat structure)
            # or if it's an agent folder like CodeActAgent (nested structure)
            direct_output = subfolder_path / 'output.jsonl'
            if direct_output.exists():
                # Flat structure: task_folder/run_folder/output.jsonl
                process_run_folder(subfolder_path, task_name, all_data, all_tools)
            else:
                # Nested structure: task_folder/agent_folder/run_folder/output.jsonl
                for run_folder in os.listdir(subfolder_path):
                    run_path = subfolder_path / run_folder
                    if run_path.is_dir():
                        process_run_folder(run_path, task_name, all_data, all_tools)

    # Sort tools for consistent column order
    sorted_tools = sorted(all_tools)

    # Rename 'run' action to 'run_cmd' to avoid conflict with run number column
    renamed_tools = ['run_cmd' if t == 'run' else t for t in sorted_tools]

    # Write to CSV
    output_csv = 'tool_calls_tokens_cost_report.csv'
    with open(output_csv, 'w', newline='') as f:
        # Create header: task, model, run, then all tools, then token counts and cost
        fieldnames = ['task', 'model', 'run'] + renamed_tools + ['total_tool_calls', 'total_input_tokens', 'total_output_tokens', 'total_tokens', 'accumulated_cost']
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()

        # Sort data by task, model, run
        all_data.sort(key=lambda x: (x['task'], x['model'], x['run']))

        for entry in all_data:
            row = {
                'task': entry['task'],
                'model': entry['model'],
                'run': entry['run']
            }
            # Add tool counts
            total = 0
            for i, tool in enumerate(sorted_tools):
                count = entry['actions'].get(tool, 0)
                # Use renamed column name
                row[renamed_tools[i]] = count
                total += count
            row['total_tool_calls'] = total
            # Add token counts and cost
            row['total_input_tokens'] = entry['total_input_tokens']
            row['total_output_tokens'] = entry['total_output_tokens']
            row['total_tokens'] = entry['total_input_tokens'] + entry['total_output_tokens']
            row['accumulated_cost'] = round(entry['accumulated_cost'], 6)
            writer.writerow(row)

    print(f"CSV report generated: {output_csv}")
    print(f"Total entries: {len(all_data)}")
    print(f"Tools found: {', '.join(sorted_tools)}")

if __name__ == '__main__':
    main()
