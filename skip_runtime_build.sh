#!/bin/bash
# Workaround: Pull pre-built OpenHands runtime for AMD64

echo "Pulling pre-built OpenHands runtime image..."
sudo docker pull --platform linux/amd64 ghcr.io/openhands/runtime:oh_v0.62.0

echo "Tagging with expected hash name..."
sudo docker tag ghcr.io/openhands/runtime:oh_v0.62.0 \
  ghcr.io/openhands/runtime:oh_v0.62.0_b2qggwv3hflxym0i_orxuzb4v3atohp7f

echo "✓ Pre-built runtime available"
echo "You can now retry your evaluation"
