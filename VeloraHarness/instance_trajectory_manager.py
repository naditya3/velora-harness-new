#!/usr/bin/env python3
"""
Instance-Wise Trajectory Management System

Advanced Python companion tool for managing, analyzing, and resuming
instance-wise trajectory generation across multiple AI models.

Features:
    - Resume failed/timed-out instances
    - Detailed progress analytics
    - Instance-level result analysis
    - Export results in multiple formats
    - Performance metrics and visualization
    - Retry management

Author: Expert Coder
Date: 2026-02-06
"""

import argparse
import json
import os
import sys
from pathlib import Path
from datetime import datetime, timedelta
from typing import Dict, List, Tuple, Optional
from dataclasses import dataclass, asdict
from collections import defaultdict
import csv

# Try to import optional dependencies
try:
    import pandas as pd
    HAS_PANDAS = True
except ImportError:
    HAS_PANDAS = False

try:
    import matplotlib.pyplot as plt
    import seaborn as sns
    HAS_PLOTTING = False
except ImportError:
    HAS_PLOTTING = False


# Absolute paths
PROJECT_ROOT = Path("/home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness")
OUTPUT_BASE = Path("/home/ec2-user/VeloraTrajectories/outputs")
DATASET_PATH = PROJECT_ROOT / "data" / "repomate_75_samples.jsonl"


@dataclass
class InstanceResult:
    """Results for a single instance."""
    instance_id: str
    model: str
    status: str  # SUCCESS, FAILED, TIMEOUT, IN_PROGRESS
    duration_seconds: Optional[int] = None
    exit_code: Optional[int] = None
    timestamp: Optional[int] = None
    log_file: Optional[str] = None
    trajectory_dir: Optional[str] = None


class TrajectoryAnalyzer:
    """Analyze trajectory generation results."""

    def __init__(self, session_id: str = None):
        """Initialize analyzer with optional session ID."""
        self.session_id = session_id
        self.results: List[InstanceResult] = []

        if session_id:
            self.load_session_results(session_id)

    def find_latest_session(self) -> Optional[str]:
        """Find the most recent session."""
        sessions_dir = OUTPUT_BASE / "progress"
        if not sessions_dir.exists():
            return None

        sessions = sorted(
            [d for d in sessions_dir.iterdir() if d.is_dir()],
            key=lambda x: x.stat().st_mtime,
            reverse=True
        )

        return sessions[0].name if sessions else None

    def load_session_results(self, session_id: str):
        """Load results from a specific session."""
        progress_dir = OUTPUT_BASE / "progress" / session_id

        if not progress_dir.exists():
            print(f"❌ Session directory not found: {progress_dir}")
            return

        for status_file in progress_dir.glob("*.status"):
            filename = status_file.stem
            parts = filename.split('_', 1)

            if len(parts) != 2:
                continue

            model, instance_id = parts

            # Parse status file
            with open(status_file, 'r') as f:
                status_line = f.read().strip()
                status_parts = status_line.split('|')

                result = InstanceResult(
                    instance_id=instance_id,
                    model=model,
                    status=status_parts[0]
                )

                if len(status_parts) > 1:
                    result.timestamp = int(status_parts[1])
                if len(status_parts) > 2:
                    result.duration_seconds = int(status_parts[2])
                if len(status_parts) > 3:
                    result.exit_code = int(status_parts[3])

                # Find log file
                log_dir = OUTPUT_BASE / "logs" / session_id / model
                result.log_file = str(log_dir / f"instance_{instance_id}.log")

                # Find trajectory dir
                traj_dir = OUTPUT_BASE / "trajectories" / session_id / model / f"instance_{instance_id}"
                result.trajectory_dir = str(traj_dir)

                self.results.append(result)

    def get_summary_stats(self) -> Dict:
        """Get summary statistics."""
        if not self.results:
            return {}

        stats = {
            'total_instances': len(set(r.instance_id for r in self.results)),
            'total_runs': len(self.results),
            'by_status': defaultdict(int),
            'by_model': defaultdict(lambda: defaultdict(int)),
            'avg_duration': {},
            'success_rate': {}
        }

        total_duration = defaultdict(list)

        for result in self.results:
            stats['by_status'][result.status] += 1
            stats['by_model'][result.model][result.status] += 1

            if result.duration_seconds:
                total_duration[result.model].append(result.duration_seconds)

        # Calculate averages and success rates
        for model in stats['by_model']:
            model_stats = stats['by_model'][model]
            total = sum(model_stats.values())

            if total > 0:
                success = model_stats.get('SUCCESS', 0)
                stats['success_rate'][model] = (success / total) * 100

            if model in total_duration and total_duration[model]:
                stats['avg_duration'][model] = sum(total_duration[model]) / len(total_duration[model])

        return stats

    def get_failed_instances(self) -> List[InstanceResult]:
        """Get all failed or timed-out instances."""
        return [
            r for r in self.results
            if r.status in ('FAILED', 'TIMEOUT')
        ]

    def get_in_progress_instances(self) -> List[InstanceResult]:
        """Get instances still in progress."""
        return [r for r in self.results if r.status == 'IN_PROGRESS']

    def export_to_csv(self, output_file: str):
        """Export results to CSV."""
        with open(output_file, 'w', newline='') as f:
            if not self.results:
                return

            writer = csv.DictWriter(f, fieldnames=asdict(self.results[0]).keys())
            writer.writeheader()

            for result in self.results:
                writer.writerow(asdict(result))

        print(f"✅ Exported results to: {output_file}")

    def export_to_json(self, output_file: str):
        """Export results to JSON."""
        data = {
            'session_id': self.session_id,
            'export_time': datetime.now().isoformat(),
            'summary': self.get_summary_stats(),
            'results': [asdict(r) for r in self.results]
        }

        with open(output_file, 'w') as f:
            json.dump(data, f, indent=2)

        print(f"✅ Exported results to: {output_file}")

    def print_summary(self):
        """Print a formatted summary."""
        stats = self.get_summary_stats()

        print("\n" + "=" * 80)
        print("  TRAJECTORY GENERATION SUMMARY")
        print("=" * 80)
        print(f"Session ID: {self.session_id}")
        print(f"Total Instances: {stats['total_instances']}")
        print(f"Total Runs: {stats['total_runs']}")
        print()

        print("Status Breakdown:")
        print("-" * 40)
        for status, count in sorted(stats['by_status'].items()):
            print(f"  {status:15s}: {count:4d}")
        print()

        print("Model Performance:")
        print("-" * 80)
        print(f"{'Model':<20s} {'Success':>8s} {'Failed':>8s} {'Timeout':>8s} {'Success Rate':>12s} {'Avg Duration':>12s}")
        print("-" * 80)

        for model, model_stats in sorted(stats['by_model'].items()):
            success = model_stats.get('SUCCESS', 0)
            failed = model_stats.get('FAILED', 0)
            timeout = model_stats.get('TIMEOUT', 0)
            success_rate = stats['success_rate'].get(model, 0)
            avg_dur = stats['avg_duration'].get(model, 0)

            print(f"{model:<20s} {success:>8d} {failed:>8d} {timeout:>8d} {success_rate:>11.1f}% {avg_dur:>11.0f}s")

        print("=" * 80)

    def generate_retry_list(self, output_file: str, models: List[str] = None):
        """Generate a list of instances to retry."""
        failed = self.get_failed_instances()

        if models:
            failed = [r for r in failed if r.model in models]

        # Group by instance_id to avoid duplicates
        retry_instances = {}
        for result in failed:
            if result.instance_id not in retry_instances:
                retry_instances[result.instance_id] = result

        with open(output_file, 'w') as f:
            for instance_id in sorted(retry_instances.keys()):
                f.write(f"{instance_id}\n")

        print(f"✅ Generated retry list with {len(retry_instances)} instances: {output_file}")
        return list(retry_instances.keys())


class InstanceManager:
    """Manage instance-wise trajectory generation."""

    def __init__(self):
        self.dataset_path = DATASET_PATH
        self.instances = []
        self.load_dataset()

    def load_dataset(self):
        """Load all instances from the dataset."""
        if not self.dataset_path.exists():
            print(f"❌ Dataset not found: {self.dataset_path}")
            return

        with open(self.dataset_path, 'r') as f:
            for line in f:
                instance = json.loads(line)
                self.instances.append(instance)

        print(f"✅ Loaded {len(self.instances)} instances from dataset")

    def create_subset_dataset(self, instance_ids: List[str], output_file: str):
        """Create a dataset with only specified instances."""
        instance_set = set(instance_ids)
        selected_instances = [
            inst for inst in self.instances
            if inst['instance_id'] in instance_set
        ]

        output_path = Path(output_file)
        output_path.parent.mkdir(parents=True, exist_ok=True)

        with open(output_path, 'w') as f:
            for instance in selected_instances:
                f.write(json.dumps(instance) + '\n')

        print(f"✅ Created subset dataset with {len(selected_instances)} instances: {output_file}")
        return output_file

    def get_instance_by_id(self, instance_id: str) -> Optional[Dict]:
        """Get instance data by ID."""
        for inst in self.instances:
            if inst['instance_id'] == instance_id:
                return inst
        return None

    def filter_by_criteria(self, repo: str = None, language: str = None) -> List[str]:
        """Filter instances by criteria."""
        filtered = self.instances

        if repo:
            filtered = [i for i in filtered if repo.lower() in i['repo'].lower()]

        if language:
            filtered = [i for i in filtered if i.get('language', '').lower() == language.lower()]

        return [i['instance_id'] for i in filtered]


def cmd_analyze(args):
    """Analyze trajectory generation results."""
    session_id = args.session_id

    if not session_id or session_id == 'latest':
        analyzer = TrajectoryAnalyzer()
        session_id = analyzer.find_latest_session()

        if not session_id:
            print("❌ No sessions found")
            return

        print(f"📊 Analyzing latest session: {session_id}")

    analyzer = TrajectoryAnalyzer(session_id)

    if not analyzer.results:
        print("❌ No results found for this session")
        return

    analyzer.print_summary()

    if args.export_csv:
        analyzer.export_to_csv(args.export_csv)

    if args.export_json:
        analyzer.export_to_json(args.export_json)

    # Show failed instances if requested
    if args.show_failed:
        failed = analyzer.get_failed_instances()
        if failed:
            print(f"\n❌ Failed/Timed-out Instances ({len(failed)}):")
            print("-" * 80)
            for result in failed:
                print(f"  {result.instance_id:<30s} {result.model:<15s} {result.status:<10s}")
        else:
            print("\n✅ No failed instances")


def cmd_retry(args):
    """Generate retry configuration for failed instances."""
    session_id = args.session_id

    if not session_id or session_id == 'latest':
        analyzer = TrajectoryAnalyzer()
        session_id = analyzer.find_latest_session()

        if not session_id:
            print("❌ No sessions found")
            return

    analyzer = TrajectoryAnalyzer(session_id)

    if not analyzer.results:
        print("❌ No results found")
        return

    models = args.models.split(',') if args.models else None

    # Generate retry list
    output_file = args.output or f"retry_instances_{session_id}.txt"
    retry_ids = analyzer.generate_retry_list(output_file, models)

    # If requested, create subset dataset
    if args.create_dataset:
        manager = InstanceManager()
        dataset_file = args.create_dataset
        manager.create_subset_dataset(retry_ids, dataset_file)


def cmd_list_sessions(args):
    """List all available sessions."""
    sessions_dir = OUTPUT_BASE / "progress"

    if not sessions_dir.exists():
        print("❌ No sessions directory found")
        return

    sessions = sorted(
        [d for d in sessions_dir.iterdir() if d.is_dir()],
        key=lambda x: x.stat().st_mtime,
        reverse=True
    )

    print(f"\n📋 Available Sessions ({len(sessions)}):")
    print("-" * 100)
    print(f"{'Session ID':<40s} {'Created':<25s} {'Instances':>10s} {'Status Files':>12s}")
    print("-" * 100)

    for session_dir in sessions:
        session_id = session_dir.name
        mtime = datetime.fromtimestamp(session_dir.stat().st_mtime)
        status_files = list(session_dir.glob("*.status"))

        # Count unique instances
        instances = set()
        for sf in status_files:
            parts = sf.stem.split('_', 1)
            if len(parts) == 2:
                instances.add(parts[1])

        print(f"{session_id:<40s} {mtime.strftime('%Y-%m-%d %H:%M:%S'):<25s} {len(instances):>10d} {len(status_files):>12d}")

    print("-" * 100)


def cmd_create_subset(args):
    """Create a subset dataset."""
    manager = InstanceManager()

    instance_ids = []

    # Read from file if provided
    if args.instances_file:
        with open(args.instances_file, 'r') as f:
            instance_ids = [line.strip() for line in f if line.strip()]

    # Add individual instance IDs
    if args.instance_ids:
        instance_ids.extend(args.instance_ids.split(','))

    # Filter by criteria
    if args.repo or args.language:
        filtered = manager.filter_by_criteria(repo=args.repo, language=args.language)
        instance_ids.extend(filtered)

    # Remove duplicates
    instance_ids = list(set(instance_ids))

    if not instance_ids:
        print("❌ No instances specified")
        return

    print(f"Creating subset with {len(instance_ids)} instances...")
    manager.create_subset_dataset(instance_ids, args.output)


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Instance-Wise Trajectory Management System",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Analyze latest session
  %(prog)s analyze

  # Analyze specific session
  %(prog)s analyze --session-id session_20260206_120000

  # Export results to CSV
  %(prog)s analyze --export-csv results.csv --show-failed

  # Generate retry list for failed instances
  %(prog)s retry --create-dataset retry_dataset.jsonl

  # List all sessions
  %(prog)s list-sessions

  # Create subset dataset for specific instances
  %(prog)s create-subset --instance-ids "123,456,789" --output subset.jsonl
        """
    )

    subparsers = parser.add_subparsers(dest='command', help='Available commands')

    # Analyze command
    analyze_parser = subparsers.add_parser('analyze', help='Analyze trajectory results')
    analyze_parser.add_argument('--session-id', default='latest', help='Session ID to analyze (default: latest)')
    analyze_parser.add_argument('--export-csv', help='Export results to CSV file')
    analyze_parser.add_argument('--export-json', help='Export results to JSON file')
    analyze_parser.add_argument('--show-failed', action='store_true', help='Show failed instances')

    # Retry command
    retry_parser = subparsers.add_parser('retry', help='Generate retry configuration')
    retry_parser.add_argument('--session-id', default='latest', help='Session ID (default: latest)')
    retry_parser.add_argument('--models', help='Comma-separated list of models to retry')
    retry_parser.add_argument('--output', help='Output file for retry list')
    retry_parser.add_argument('--create-dataset', help='Create subset dataset with failed instances')

    # List sessions command
    subparsers.add_parser('list-sessions', help='List all available sessions')

    # Create subset command
    subset_parser = subparsers.add_parser('create-subset', help='Create subset dataset')
    subset_parser.add_argument('--instances-file', help='File containing instance IDs (one per line)')
    subset_parser.add_argument('--instance-ids', help='Comma-separated instance IDs')
    subset_parser.add_argument('--repo', help='Filter by repository name')
    subset_parser.add_argument('--language', help='Filter by language')
    subset_parser.add_argument('--output', required=True, help='Output dataset file')

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return 1

    # Execute command
    if args.command == 'analyze':
        cmd_analyze(args)
    elif args.command == 'retry':
        cmd_retry(args)
    elif args.command == 'list-sessions':
        cmd_list_sessions(args)
    elif args.command == 'create-subset':
        cmd_create_subset(args)

    return 0


if __name__ == '__main__':
    sys.exit(main())
