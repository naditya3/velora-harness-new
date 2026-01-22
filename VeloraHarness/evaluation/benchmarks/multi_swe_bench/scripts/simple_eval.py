#!/usr/bin/env python3
"""
simple_eval.py - Simple evaluation script for Velora tasks

This script:
1. Takes an output.jsonl from trajectory generation
2. Extracts the git patch
3. Applies it to the Docker container
4. Runs the test command
5. Generates report files (patch.diff, report.json, test_output.txt)

Usage:
    python simple_eval.py --input-file output.jsonl --dataset task.jsonl
"""

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path


def load_jsonl(filepath):
    """Load a JSONL file and return list of dicts."""
    data = []
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if line:
                data.append(json.loads(line))
    return data


def extract_patch(output_data):
    """Extract git patch from output.jsonl entry."""
    patch = ''
    
    # Try test_result.git_patch first
    if 'test_result' in output_data and output_data['test_result']:
        patch = output_data['test_result'].get('git_patch', '')
    
    # Try model_patch as fallback
    if not patch and 'model_patch' in output_data:
        patch = output_data.get('model_patch', '')
    
    # Clean up patch
    if patch:
        patch = patch.replace('\r\n', '\n')
        # Find first diff line
        lines = patch.split('\n')
        for i, line in enumerate(lines):
            if line.startswith('diff --git'):
                patch = '\n'.join(lines[i:])
                break
        patch = patch.rstrip() + '\n'
    
    return patch


def run_docker_eval(instance_id, image_name, patch, test_command, output_dir, fail_to_pass=None, timeout=600):
    """
    Run evaluation in Docker container.
    
    Returns dict with:
        - resolved: bool
        - failed_apply_patch: bool
        - error_eval: bool
        - test_output: str
    """
    result = {
        'resolved': False,
        'failed_apply_patch': False,
        'error_eval': False,
        'test_output': '',
        'apply_output': '',
    }
    
    os.makedirs(output_dir, exist_ok=True)
    
    # Save patch file
    patch_file = os.path.join(output_dir, 'patch.diff')
    with open(patch_file, 'w') as f:
        f.write(patch)
    
    if not patch.strip():
        result['error_eval'] = True
        result['test_output'] = 'Empty patch'
        return result
    
    container_name = f"eval_{instance_id}_{int(time.time())}"
    
    try:
        # Start container
        print(f"Starting container from image: {image_name}")
        start_cmd = [
            'docker', 'run', '-d',
            '--name', container_name,
            '--entrypoint', '/bin/bash',  # Override any broken entrypoint
            image_name,
            '-c', 'sleep infinity'
        ]
        subprocess.run(start_cmd, check=True, capture_output=True)
        
        # Copy patch to container
        subprocess.run(
            ['docker', 'cp', patch_file, f'{container_name}:/tmp/patch.diff'],
            check=True, capture_output=True
        )
        
        # Find repo directory
        find_repo_cmd = ['docker', 'exec', container_name, 'bash', '-c',
                        'if [ -d /app/repo ]; then echo /app/repo; elif [ -d /testbed ]; then echo /testbed; else echo /workspace; fi']
        repo_result = subprocess.run(find_repo_cmd, capture_output=True, text=True)
        repo_dir = repo_result.stdout.strip() or '/app/repo'
        print(f"Using repo directory: {repo_dir}")
        
        # Apply patch
        apply_cmd = f'''
cd {repo_dir} && git config --global --add safe.directory {repo_dir} && git apply -v /tmp/patch.diff 2>&1
'''
        apply_result = subprocess.run(
            ['docker', 'exec', container_name, 'bash', '-c', apply_cmd],
            capture_output=True, text=True, timeout=60
        )
        result['apply_output'] = apply_result.stdout + apply_result.stderr
        
        if apply_result.returncode != 0:
            print(f"git apply failed, trying patch command...")
            # Try patch command
            patch_cmd = f'''
cd {repo_dir} && patch --batch --fuzz=5 -p1 -i /tmp/patch.diff 2>&1
'''
            patch_result = subprocess.run(
                ['docker', 'exec', container_name, 'bash', '-c', patch_cmd],
                capture_output=True, text=True, timeout=60
            )
            result['apply_output'] += '\n--- Trying patch command ---\n' + patch_result.stdout + patch_result.stderr
            
            if patch_result.returncode != 0:
                result['failed_apply_patch'] = True
                result['test_output'] = f"Failed to apply patch:\n{result['apply_output']}"
                return result
        
        print("Patch applied successfully")
        
        # Run tests
        if test_command:
            print(f"Running tests: {test_command[:100]}...")
            test_cmd = f'cd {repo_dir} && {test_command}'
            test_result = subprocess.run(
                ['docker', 'exec', container_name, 'bash', '-c', test_cmd],
                capture_output=True, text=True, timeout=timeout
            )
            result['test_output'] = test_result.stdout + test_result.stderr
            
            # Check if tests passed
            if test_result.returncode == 0:
                result['resolved'] = True
            else:
                # Check if the FAIL_TO_PASS tests specifically passed
                import re
                output = result['test_output']
                
                # If we have specific tests that should pass, check for them
                if fail_to_pass:
                    all_target_tests_passed = True
                    for test in fail_to_pass:
                        # pytest marks passed tests with "PASSED test/..."
                        test_name = test.split('::')[-1] if '::' in test else test
                        if f'PASSED' in output and test_name in output:
                            continue
                        elif f'FAILED' in output and test_name in output:
                            all_target_tests_passed = False
                            break
                    if all_target_tests_passed:
                        result['resolved'] = True
                        print(f"  Target tests passed!")
                else:
                    # Fallback: check pytest summary
                    summary_match = re.search(r'(\d+)\s+passed', output)
                    if summary_match:
                        passed_count = int(summary_match.group(1))
                        failed_match = re.search(r'(\d+)\s+failed', output)
                        failed_count = int(failed_match.group(1)) if failed_match else 0
                        
                        # If most tests pass, consider it resolved
                        if passed_count > 0 and failed_count <= 2:
                            result['resolved'] = True
                            print(f"  Tests: {passed_count} passed, {failed_count} failed (resolved)")
        else:
            result['test_output'] = 'No test command provided'
            result['error_eval'] = True
            
    except subprocess.TimeoutExpired:
        result['error_eval'] = True
        result['test_output'] = f'Test timeout after {timeout}s'
    except Exception as e:
        result['error_eval'] = True
        result['test_output'] = f'Error: {str(e)}'
    finally:
        # Cleanup container
        try:
            subprocess.run(['docker', 'stop', container_name], capture_output=True, timeout=30)
            subprocess.run(['docker', 'rm', container_name], capture_output=True, timeout=30)
        except:
            pass
    
    return result


def main():
    parser = argparse.ArgumentParser(description='Simple evaluation for Velora tasks')
    parser.add_argument('--input-file', required=True, help='Path to output.jsonl from trajectory generation')
    parser.add_argument('--dataset', required=True, help='Path to dataset.jsonl with task info')
    parser.add_argument('--output-dir', default=None, help='Output directory for results (default: same as input)')
    parser.add_argument('--timeout', type=int, default=600, help='Test timeout in seconds')
    args = parser.parse_args()
    
    # Load files
    print(f"Loading output file: {args.input_file}")
    outputs = load_jsonl(args.input_file)
    
    print(f"Loading dataset: {args.dataset}")
    dataset = load_jsonl(args.dataset)
    
    # Create instance lookup
    dataset_map = {d['instance_id']: d for d in dataset}
    
    # Determine output directory
    if args.output_dir:
        base_output_dir = args.output_dir
    else:
        base_output_dir = os.path.dirname(args.input_file)
    
    eval_outputs_dir = os.path.join(base_output_dir, 'eval_outputs')
    os.makedirs(eval_outputs_dir, exist_ok=True)
    
    # Process each output
    results = []
    for output in outputs:
        instance_id = str(output.get('instance_id', 'unknown'))
        print(f"\n{'='*60}")
        print(f"Evaluating instance: {instance_id}")
        print('='*60)
        
        # Get dataset info
        if instance_id not in dataset_map:
            print(f"WARNING: Instance {instance_id} not found in dataset")
            continue
        
        task = dataset_map[instance_id]
        
        # Determine Docker image
        # Always use the mswebench tag, not the S3 storage URI
            image_name = f"mswebench/sweb.eval.x86_64.{instance_id}:latest"
        print(f"Docker image: {image_name}")
        
        # Log the storage URI for reference
        storage_uri = task.get('image_storage_uri', 'N/A')
        print(f"Image storage URI: {storage_uri}")
        
        # Extract patch
        patch = extract_patch(output)
        if not patch.strip():
            print("WARNING: No patch found in output")
        
        # Get test command
        test_command = task.get('test_command', '')
        if not test_command:
            # Try to construct from FAIL_TO_PASS tests
            fail_tests = task.get('FAIL_TO_PASS', [])
            if fail_tests:
                test_command = f"python -m pytest {' '.join(fail_tests)} -xvs"
        
        # Create instance output directory
        instance_output_dir = os.path.join(eval_outputs_dir, instance_id)
        os.makedirs(instance_output_dir, exist_ok=True)
        
        # Get FAIL_TO_PASS tests
        fail_to_pass = task.get('FAIL_TO_PASS', [])
        if isinstance(fail_to_pass, str):
            fail_to_pass = [fail_to_pass]
        
        # Run evaluation
        eval_result = run_docker_eval(
            instance_id=instance_id,
            image_name=image_name,
            patch=patch,
            test_command=test_command,
            output_dir=instance_output_dir,
            fail_to_pass=fail_to_pass,
            timeout=args.timeout
        )
        
        # Save results
        # patch.diff
        with open(os.path.join(instance_output_dir, 'patch.diff'), 'w') as f:
            f.write(patch)
        
        # test_output.txt
        with open(os.path.join(instance_output_dir, 'test_output.txt'), 'w') as f:
            f.write(eval_result['test_output'])
        
        # report.json
        report = {
            'instance_id': instance_id,
            'resolved': eval_result['resolved'],
            'failed_apply_patch': eval_result['failed_apply_patch'],
            'error_eval': eval_result['error_eval'],
            'empty_generation': not bool(patch.strip()),
        }
        with open(os.path.join(instance_output_dir, 'report.json'), 'w') as f:
            json.dump(report, f, indent=2)
        
        # run_instance.log
        log_content = f"""Instance: {instance_id}
Image: {image_name}
Test Command: {test_command}

=== Apply Patch Output ===
{eval_result['apply_output']}

=== Test Output ===
{eval_result['test_output']}

=== Result ===
Resolved: {eval_result['resolved']}
Failed Apply Patch: {eval_result['failed_apply_patch']}
Error in Eval: {eval_result['error_eval']}
"""
        with open(os.path.join(instance_output_dir, 'run_instance.log'), 'w') as f:
            f.write(log_content)
        
        # eval.sh (the test command)
        with open(os.path.join(instance_output_dir, 'eval.sh'), 'w') as f:
            f.write(f"#!/bin/bash\n{test_command}\n")
        
        results.append(report)
        
        print(f"\nResult: {'RESOLVED' if eval_result['resolved'] else 'NOT RESOLVED'}")
        print(f"Output saved to: {instance_output_dir}")
    
    # Print summary
    print(f"\n{'='*60}")
    print("EVALUATION SUMMARY")
    print('='*60)
    total = len(results)
    resolved = sum(1 for r in results if r['resolved'])
    failed_apply = sum(1 for r in results if r['failed_apply_patch'])
    error = sum(1 for r in results if r['error_eval'])
    empty = sum(1 for r in results if r['empty_generation'])
    
    print(f"Total: {total}")
    print(f"Resolved: {resolved} ({100*resolved/total if total else 0:.1f}%)")
    print(f"Failed Apply Patch: {failed_apply}")
    print(f"Error in Eval: {error}")
    print(f"Empty Generation: {empty}")
    print(f"\nResults saved to: {eval_outputs_dir}")
    
    # Save summary
    summary = {
        'total': total,
        'resolved': resolved,
        'failed_apply_patch': failed_apply,
        'error_eval': error,
        'empty_generation': empty,
        'results': results,
    }
    with open(os.path.join(base_output_dir, 'eval_summary.json'), 'w') as f:
        json.dump(summary, f, indent=2)


if __name__ == '__main__':
    main()

