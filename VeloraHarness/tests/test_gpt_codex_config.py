#!/usr/bin/env python3
"""
Test script to validate GPT-5.2-codex configuration in VeloraHarness.

This script:
1. Loads and validates the config.toml file
2. Checks that the gpt_codex LLM configuration is properly loaded
3. Verifies all required parameters are set correctly
4. Tests that the reasoning_effort parameter is properly configured
"""

import os
import sys
import toml
from pathlib import Path

# Add parent directory to path to import openhands modules
sys.path.insert(0, str(Path(__file__).parent))

from openhands.core.config.llm_config import LLMConfig


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

    for field, expected_value in required_fields.items():
        actual_value = gpt_codex_config.get(field)
        status = "✓" if actual_value == expected_value else "✗"
        print(f"   {status} {field}: {actual_value} (expected: {expected_value})")
        if actual_value != expected_value:
            return False

    # Check optional but recommended fields
    print("\n5. Checking optional configuration fields:")
    optional_fields = ["temperature", "max_input_tokens", "max_output_tokens", "api_key"]
    for field in optional_fields:
        value = gpt_codex_config.get(field, "NOT SET")
        print(f"   • {field}: {value}")

    # Try to create LLMConfig object
    print("\n6. Testing LLMConfig instantiation...")
    try:
        # Parse all LLM configs using the from_toml_section method
        llm_configs = LLMConfig.from_toml_section(config_data["llm"])

        if "gpt_codex" not in llm_configs:
            print("   ERROR: gpt_codex config not found in parsed configs")
            return False

        gpt_codex_llm_config = llm_configs["gpt_codex"]
        print(f"   SUCCESS: LLMConfig created")
        print(f"   • Model: {gpt_codex_llm_config.model}")
        print(f"   • Reasoning effort: {gpt_codex_llm_config.reasoning_effort}")
        print(f"   • Temperature: {gpt_codex_llm_config.temperature}")
        print(f"   • Max input tokens: {gpt_codex_llm_config.max_input_tokens}")
        print(f"   • Max output tokens: {gpt_codex_llm_config.max_output_tokens}")

    except Exception as e:
        print(f"   ERROR: Failed to create LLMConfig: {e}")
        import traceback
        traceback.print_exc()
        return False

    print("\n" + "=" * 70)
    print("Configuration Test: PASSED")
    print("=" * 70)
    print("\nNext steps:")
    print("1. Add your OpenAI API key to config.toml (replace YOUR_OPENAI_API_KEY_HERE)")
    print("2. Run a test instance with: --llm_config gpt_codex")
    print("3. Check that reasoning_effort='high' is being passed to the API")
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
    print("=" * 70)


if __name__ == "__main__":
    success = test_config_loading()

    if success:
        print_usage_example()
        sys.exit(0)
    else:
        print("\n" + "=" * 70)
        print("Configuration Test: FAILED")
        print("=" * 70)
        sys.exit(1)
