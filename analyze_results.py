#!/usr/bin/env python3
"""
Analyze Trajectory Generation Results

Compare model performance across generated trajectories.

Usage:
    python analyze_results.py --output-dir outputs/
"""

import argparse
import json
import os
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Any


def load_jsonl(filepath: str) -> List[Dict[str, Any]]:
    """Load JSONL file"""
    data = []
    if not os.path.exists(filepath):
        return data

    with open(filepath, 'r') as f:
        for line in f:
            try:
                data.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return data


def analyze_trajectories(output_dir: str):
    """Analyze trajectory generation results"""

    models = []
    results = {}

    # Find all model directories
    for item in Path(output_dir).iterdir():
        if item.is_dir():
            models.append(item.name)

    if not models:
        print(f"No model directories found in {output_dir}")
        return

    print("=" * 80)
    print("VeloraTrajectories - Results Analysis")
    print("=" * 80)
    print()

    # Analyze each model
    for model in sorted(models):
        model_dir = Path(output_dir) / model
        output_file = model_dir / "output.jsonl"
        eval_file = model_dir / "eval_output.jsonl"

        results[model] = {
            'trajectories': 0,
            'evaluations': 0,
            'resolved': 0,
            'failed': 0,
            'f2p_success': 0,
            'f2p_failed': 0,
            'p2p_success': 0,
            'p2p_failed': 0,
            'total_cost': 0.0,
            'avg_iterations': 0,
        }

        # Load trajectories
        trajectories = load_jsonl(str(output_file))
        results[model]['trajectories'] = len(trajectories)

        # Calculate trajectory metrics
        if trajectories:
            total_iterations = 0
            total_cost = 0.0

            for traj in trajectories:
                metrics = traj.get('metrics', {})
                total_iterations += metrics.get('iterations', 0)
                total_cost += metrics.get('cost', 0.0)

            results[model]['avg_iterations'] = total_iterations / len(trajectories)
            results[model]['total_cost'] = total_cost

        # Load evaluations
        evaluations = load_jsonl(str(eval_file))
        results[model]['evaluations'] = len(evaluations)

        # Calculate evaluation metrics
        for eval_result in evaluations:
            if eval_result.get('resolved'):
                results[model]['resolved'] += 1
            else:
                results[model]['failed'] += 1

            f2p_success = eval_result.get('fail_to_pass_success', [])
            f2p_failed = eval_result.get('fail_to_pass_failed', [])
            p2p_success = eval_result.get('pass_to_pass_success', [])
            p2p_failed = eval_result.get('pass_to_pass_failed', [])

            results[model]['f2p_success'] += len(f2p_success)
            results[model]['f2p_failed'] += len(f2p_failed)
            results[model]['p2p_success'] += len(p2p_success)
            results[model]['p2p_failed'] += len(p2p_failed)

    # Print summary table
    print("Model Performance Summary")
    print("-" * 80)
    print(f"{'Model':<20} {'Tasks':<8} {'Resolved':<10} {'Rate':<10} {'Cost':<12} {'Avg Iter':<10}")
    print("-" * 80)

    for model in sorted(models):
        r = results[model]
        resolved_rate = (r['resolved'] / r['evaluations'] * 100) if r['evaluations'] > 0 else 0

        print(f"{model:<20} {r['evaluations']:<8} {r['resolved']:<10} "
              f"{resolved_rate:>6.1f}%    ${r['total_cost']:<10.2f} {r['avg_iterations']:<10.1f}")

    print("-" * 80)
    print()

    # Detailed test results
    print("Detailed Test Results")
    print("-" * 80)
    print(f"{'Model':<20} {'F2P Pass':<12} {'F2P Fail':<12} {'P2P Pass':<12} {'P2P Fail':<12}")
    print("-" * 80)

    for model in sorted(models):
        r = results[model]
        print(f"{model:<20} {r['f2p_success']:<12} {r['f2p_failed']:<12} "
              f"{r['p2p_success']:<12} {r['p2p_failed']:<12}")

    print("-" * 80)
    print()

    # Cost comparison
    print("Cost Analysis")
    print("-" * 80)
    total_cost = sum(r['total_cost'] for r in results.values())

    for model in sorted(models):
        r = results[model]
        cost_share = (r['total_cost'] / total_cost * 100) if total_cost > 0 else 0
        cost_per_task = r['total_cost'] / r['evaluations'] if r['evaluations'] > 0 else 0

        print(f"{model:<20} Total: ${r['total_cost']:>8.2f} ({cost_share:>5.1f}%)  "
              f"Per Task: ${cost_per_task:>6.3f}")

    print(f"{'Total':<20} ${total_cost:>8.2f}")
    print("-" * 80)
    print()

    # Recommendations
    print("Recommendations")
    print("-" * 80)

    # Find best model by resolved rate
    best_model = max(models, key=lambda m: results[m]['resolved'] / results[m]['evaluations']
                     if results[m]['evaluations'] > 0 else 0)
    best_rate = (results[best_model]['resolved'] / results[best_model]['evaluations'] * 100
                 if results[best_model]['evaluations'] > 0 else 0)

    # Find cheapest model
    cheapest_model = min(models, key=lambda m: results[m]['total_cost'] / results[m]['evaluations']
                         if results[m]['evaluations'] > 0 else float('inf'))
    cheapest_cost = (results[cheapest_model]['total_cost'] / results[cheapest_model]['evaluations']
                     if results[cheapest_model]['evaluations'] > 0 else 0)

    # Find most efficient (best resolved rate per dollar)
    efficient_model = max(models, key=lambda m:
                          (results[m]['resolved'] / results[m]['total_cost'])
                          if results[m]['total_cost'] > 0 and results[m]['evaluations'] > 0 else 0)

    print(f"🏆 Best Resolution Rate: {best_model} ({best_rate:.1f}%)")
    print(f"💰 Lowest Cost Per Task: {cheapest_model} (${cheapest_cost:.3f})")
    print(f"⚡ Most Efficient: {efficient_model}")
    print("-" * 80)
    print()

    # Export to CSV
    csv_file = Path(output_dir) / "comparison.csv"
    with open(csv_file, 'w') as f:
        f.write("Model,Tasks,Resolved,Resolved_Rate,Total_Cost,Cost_Per_Task,Avg_Iterations,"
                "F2P_Pass,F2P_Fail,P2P_Pass,P2P_Fail\n")

        for model in sorted(models):
            r = results[model]
            resolved_rate = (r['resolved'] / r['evaluations'] * 100) if r['evaluations'] > 0 else 0
            cost_per_task = r['total_cost'] / r['evaluations'] if r['evaluations'] > 0 else 0

            f.write(f"{model},{r['evaluations']},{r['resolved']},{resolved_rate:.2f},"
                   f"{r['total_cost']:.2f},{cost_per_task:.3f},{r['avg_iterations']:.1f},"
                   f"{r['f2p_success']},{r['f2p_failed']},{r['p2p_success']},{r['p2p_failed']}\n")

    print(f"✓ Comparison exported to: {csv_file}")
    print()


def main():
    parser = argparse.ArgumentParser(
        description='Analyze trajectory generation results'
    )
    parser.add_argument(
        '--output-dir', '-o',
        default='outputs',
        help='Directory containing model outputs (default: outputs)'
    )

    args = parser.parse_args()

    if not os.path.exists(args.output_dir):
        print(f"Error: Output directory not found: {args.output_dir}")
        return 1

    analyze_trajectories(args.output_dir)
    return 0


if __name__ == '__main__':
    exit(main())
