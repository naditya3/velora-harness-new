#!/bin/bash
# Pre-build OpenHands runtime images for your ECR base images
# Run this on an AMD64 (x86_64) instance

set -e

ECR_REGISTRY="004669175958.dkr.ecr.us-east-1.amazonaws.com"
BASE_IMAGE="${ECR_REGISTRY}/repomate_image_activ_go_test/meroxa_cli:d45265fa27f5700a0a494a0f0597f340c485663c"

echo "=== Pre-building OpenHands Runtime Images ==="
echo "Base image: ${BASE_IMAGE}"

# Authenticate with ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin ${ECR_REGISTRY}

# Pull the base image
echo "Pulling base image..."
docker pull --platform linux/amd64 ${BASE_IMAGE}

# Build the runtime image using OpenHands
echo "Building runtime image..."
cd /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness

python3 << EOF
import docker
from openhands.runtime.builder import DockerRuntimeBuilder
from openhands.runtime.utils.runtime_build import build_runtime_image

client = docker.from_env()
builder = DockerRuntimeBuilder(client)

runtime_image = build_runtime_image(
    base_image="${BASE_IMAGE}",
    runtime_builder=builder,
    platform="linux/amd64",
    force_rebuild=False,
)

print(f"✓ Built runtime image: {runtime_image}")
print("This image can now be used on any machine")
EOF

echo "=== Done ==
"
echo "Runtime image has been built and cached locally"
echo "You can now run evaluations without building"
