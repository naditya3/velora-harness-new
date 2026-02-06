#!/bin/bash
#
# Run VeloraHarness in Docker with Python 3.11
#

set -e

echo "========================================="
echo "Running VeloraHarness in Docker"
echo "========================================="
echo

# Build Docker image with Python 3.11
cat > /tmp/Dockerfile.velora << 'EOF'
FROM python:3.11-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    docker.io \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /workspace

# Copy project files
COPY . /workspace/

# Install Python dependencies
RUN pip install --no-cache-dir toml litellm anthropic docker pandas datasets \
    jinja2 aiohttp python-dotenv pydantic

CMD ["/bin/bash"]
EOF

echo "Building Docker image..."
docker build -t velora-test -f /tmp/Dockerfile.velora .

echo
echo "Running trajectory generation in Docker..."
docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v $(pwd):/workspace \
    -e PYTHONPATH=/workspace/jaeger/VeloraHarness \
    velora-test \
    python3 /workspace/jaeger/VeloraHarness/evaluation/benchmarks/multi_swe_bench/run_infer.py \
        --agent-cls CodeActAgent \
        --llm-config llm.gemini \
        --max-iterations 50 \
        --eval-num-workers 1 \
        --dataset /workspace/jaeger/VeloraHarness/data/gemini_test.jsonl \
        --split train \
        --eval-n-limit 1 \
        --eval-output-dir /workspace/outputs/gemini_test

echo
echo "✓ Test complete! Check outputs/gemini_test/"
