#!/usr/bin/env python3
"""
Test script for image mapping and ECR sanitization integration.

Usage:
    python test_image_mapping.py
"""

import sys
import os

# Add the harness to the path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'jaeger', 'VeloraHarness'))

from evaluation.utils.image_utils import (
    sanitize_ecr_repo_name,
    translate_image_uri,
    preload_image_mapping,
    load_image_mapping
)


def test_sanitization():
    """Test ECR repository name sanitization."""
    print("\n" + "="*60)
    print("Testing ECR Repository Name Sanitization")
    print("="*60)

    test_cases = [
        "Valid-Repo_Name",
        "Repo__With__Double__Underscores",
        "UPPERCASE_REPO",
        "repo/with/slashes",
        "repo-with-invalid@chars!",
        "_leading_underscore",
        "trailing-underscore_",
    ]

    for original in test_cases:
        sanitized, modified = sanitize_ecr_repo_name(original)
        status = "✓ Modified" if modified else "✗ No change"
        print(f"{status:12} | {original:35} → {sanitized}")

    print()


def test_image_mapping():
    """Test image URI translation."""
    print("\n" + "="*60)
    print("Testing Image URI Translation")
    print("="*60)

    # Load the mapping
    num_mappings = preload_image_mapping()
    print(f"\nLoaded {num_mappings} image mappings from CSV\n")

    if num_mappings == 0:
        print("⚠️  No mappings loaded. Make sure image_mapping.csv exists at project root.")
        return

    # Get a few sample mappings to test
    mapping = load_image_mapping()
    sample_uris = list(mapping.keys())[:5]

    print("Sample translations:")
    for internal_uri in sample_uris:
        ecr_uri = translate_image_uri(internal_uri)
        print(f"✓ {internal_uri[:60]}")
        print(f"  → {ecr_uri[:60]}")
        print()


def test_integration():
    """Test the full integration."""
    print("\n" + "="*60)
    print("Testing Full Integration")
    print("="*60)

    # Simulate a dataset instance
    test_cases = [
        {
            "name": "Known internal URI",
            "uri": "vmvm-registry.fbinfra.net/repomate_image_activ_builtin/astral-sh_uv:bd03243dd58e2ca53e919c2355a6fca929121fb7",
            "should_translate": True
        },
        {
            "name": "Unknown URI",
            "uri": "unknown-registry.example.com/some/image:tag",
            "should_translate": False
        },
        {
            "name": "Already ECR URI",
            "uri": "004669175958.dkr.ecr.us-east-1.amazonaws.com/repo/image:tag",
            "should_translate": False
        }
    ]

    for test in test_cases:
        print(f"\nTest: {test['name']}")
        print(f"Input:  {test['uri'][:70]}")

        result = translate_image_uri(test['uri'])
        was_translated = result != test['uri']

        if was_translated:
            print(f"Output: {result[:70]}")
            print(f"Status: ✓ Translated")
        else:
            print(f"Status: ✗ Not translated (no mapping found)")

        expected = test['should_translate']
        if was_translated == expected:
            print(f"Result: ✓ PASS")
        else:
            print(f"Result: ✗ FAIL (expected translation: {expected})")


def main():
    """Run all tests."""
    print("\n" + "="*60)
    print("VeloraHarness Image Mapping Integration Test")
    print("="*60)

    try:
        test_sanitization()
        test_image_mapping()
        test_integration()

        print("\n" + "="*60)
        print("✓ All tests completed")
        print("="*60)
        print()

    except Exception as e:
        print(f"\n✗ Test failed with error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == '__main__':
    main()
