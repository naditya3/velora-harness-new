#!/usr/bin/env python3
"""
Simple test script to validate GPT-5.2-codex configuration in VeloraHarness.

This script only uses basic Python libraries to validate the config.
"""

import toml
from pathlib import Path


def test_config_loading():
    """Test that the config.toml file can be loaded and parsed."""
    print("=" * 70)
    print("Testing GPT-5.2-codex Configuration")
    print("=" * 70)

    # Load config.toml
    config_path = Path(__file__).parent / "config.toml"
    print(f"\n1. Loading config from: {config_path}")

    if not config_path.exists():
        print(f"   ERROR: Config file not found at {config_path}")
        return False

    try:
        config_data = toml.load(config_path)
        print("   SUCCESS: Config file loaded")
    except Exception as e:
        print(f"   ERROR: Failed to load config: {e}")
        return False

    # Check if llm section exists
    print("\n2. Checking [llm] section...")
    if "llm" not in config_data:
        print("   ERROR: No [llm] section found in config")
        return False
    print("   SUCCESS: [llm] section found")

    # Check if gpt_codex subsection exists
    print("\n3. Checking [llm.gpt_codex] section...")
    if "gpt_codex" not in config_data["llm"]:
        print("   ERROR: No [llm.gpt_codex] section found")
        return False
    print("   SUCCESS: [llm.gpt_codex] section found")

    gpt_codex_config = config_data["llm"]["gpt_codex"]

    # Validate required fields
    print("\n4. Validating gpt_codex configuration fields:")
    required_fields = {
        "model": "gpt-5.2-codex",
        "reasoning_effort": "high",
    }

    all_valid = True
    for field, expected_value in required_fields.items():
        actual_value = gpt_codex_config.get(field)
        status = "✓" if actual_value == expected_value else "✗"
        print(f"   {status} {field}: {actual_value} (expected: {expected_value})")
        if actual_value != expected_value:
            all_valid = False

    # Check optional but recommended fields
    print("\n5. Checking optional configuration fields:")
    optional_fields = ["temperature", "max_input_tokens", "max_output_tokens", "api_key"]
    for field in optional_fields:
        value = gpt_codex_config.get(field, "NOT SET")
        print(f"   • {field}: {value}")

    # Display full configuration
    print("\n6. Full gpt_codex configuration:")
    for key, value in gpt_codex_config.items():
        print(f"   • {key}: {value}")

    # Check core configuration
    print("\n7. Checking [core] section for max_iterations...")
    if "core" in config_data:
        max_iterations = config_data["core"].get("max_iterations", "NOT SET")
        print(f"   • max_iterations: {max_iterations}")
        if max_iterations != 200:
            print(f"   NOTE: max_iterations is {max_iterations}, you may want to set it to 200")
    else:
        print("   WARNING: [core] section not found")

    if not all_valid:
        print("\n" + "=" * 70)
        print("Configuration Test: FAILED - Some fields don't match expected values")
        print("=" * 70)
        return False

    print("\n" + "=" * 70)
    print("Configuration Test: PASSED")
    print("=" * 70)
    return True


def print_usage_example():
    """Print an example command to run the harness with gpt_codex."""
    print("\n" + "=" * 70)
    print("Usage Example")
    print("=" * 70)
    print("\nTo run VeloraHarness with GPT-5.2-codex:")
    print("\npython evaluation/benchmarks/multi_swe_bench/run_infer.py \\")
    print("    --agent_cls CodeActAgent \\")
    print("    --llm_config gpt_codex \\")
    print("    --max_iterations 200 \\")
    print("    --dataset data/test_task.jsonl \\")
    print("    --split test \\")
    print("    --eval_n_limit 1 \\")
    print("    --eval_num_workers 1")
    print("\nNote: Make sure to set your OpenAI API key in config.toml first!")
    print("\nConfiguration Details:")
    print("  • Model: gpt-5.2-codex")
    print("  • Reasoning Effort: high")
    print("  • Temperature: 0.2")
    print("  • Max Input Tokens: 120000")
    print("  • Max Output Tokens: 65536")
    print("\nReasoning Effort Options:")
    print("  • 'medium' - Balanced option for interactive coding (recommended for most tasks)")
    print("  • 'high' - For more challenging tasks (current setting)")
    print("  • 'xhigh' - For the hardest problems")
    print("\nBest Practices (from OpenAI docs):")
    print("  • Use dedicated tools (apply_patch, shell_command, git) rather than raw terminal")
    print("  • Batch file reads and tool calls together using multi_tool_use.parallel")
    print("  • Configure agent to work independently without waiting for additional prompts")
    print("=" * 70)


if __name__ == "__main__":
    success = test_config_loading()

    if success:
        print_usage_example()
        exit(0)
    else:
        exit(1)
