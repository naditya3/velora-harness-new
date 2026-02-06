#!/bin/bash
# Fix: Prevent on-the-fly runtime builds on ARM64 by pre-pulling compatible images

echo "=== Solution: Pre-pull OpenHands runtime images for AMD64 ==="

# Option 1: Pull official OpenHands runtime (AMD64)
echo "Pulling official OpenHands runtime image (AMD64)..."
sudo docker pull --platform linux/amd64 ghcr.io/openhands/runtime:oh_v0.62.0

# Option 2: Configure to skip runtime building
echo
echo "To skip runtime builds, set these environment variables:"
echo "export OPENHANDS_SKIP_BUILD=1"
echo "export OPENHANDS_RUNTIME_IMAGE='ghcr.io/openhands/runtime:oh_v0.62.0'"

echo
echo "Or modify the config to use pre-built runtime images only"

