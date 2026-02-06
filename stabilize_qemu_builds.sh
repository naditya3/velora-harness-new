#!/bin/bash
# Stabilize QEMU-based cross-platform builds on ARM64

set -e

echo "=== Making QEMU builds more stable on ARM64 ==="

# 1. Update binfmt handlers
echo "Step 1: Installing/updating binfmt..."
sudo docker run --privileged --rm tonistiigi/binfmt --install all

# 2. Increase system limits
echo "Step 2: Increasing system limits..."
echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf
echo "fs.file-max=65536" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# 3. Configure Docker for better stability
echo "Step 3: Configuring Docker..."
sudo mkdir -p /etc/docker

# Only update if daemon.json doesn't exist or doesn't have our settings
if [ ! -f /etc/docker/daemon.json ] || ! grep -q "max-concurrent-downloads" /etc/docker/daemon.json; then
    cat | sudo tee /etc/docker/daemon.json << 'EOF'
{
  "max-concurrent-downloads": 3,
  "max-concurrent-uploads": 3,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
fi

# 4. Restart Docker
echo "Step 4: Restarting Docker..."
sudo systemctl restart docker
sleep 5

# 5. Verify setup
echo "Step 5: Verifying setup..."
sudo docker run --rm --platform linux/amd64 alpine uname -m

echo
echo "=== Setup Complete ==="
echo "✓ QEMU emulation is now configured"
echo "✓ System limits increased"
echo "✓ Docker configured for stability"
echo
echo "⚠️  NOTE: Cross-platform builds may still be slow and occasionally fail"
echo "   For production use, we recommend using an AMD64 (x86_64) instance"
echo
echo "You can now retry your evaluation"
