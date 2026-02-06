#!/bin/bash
#
# Setup Environment for VeloraHarness
# Installs Python 3.11 and Docker on Amazon Linux 2023
#

set -e

echo "========================================="
echo "Setting up VeloraHarness Environment"
echo "========================================="
echo

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
    echo "This script needs sudo privileges."
    echo "Please run: sudo ./setup_environment.sh"
    exit 1
fi

echo "Step 1: Installing Python 3.11..."
dnf install -y python3.11 python3.11-pip python3.11-devel
echo "✓ Python 3.11 installed"
echo

echo "Step 2: Installing Docker..."
dnf install -y docker
systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user
echo "✓ Docker installed"
echo

echo "Step 3: Setting up Python 3.11 as default..."
alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1
alternatives --set python3 /usr/bin/python3.11
echo "✓ Python 3.11 set as default python3"
echo

echo "========================================="
echo "Setup Complete!"
echo "========================================="
echo
echo "Installed:"
python3 --version
docker --version
echo
echo "IMPORTANT: You need to log out and log back in for Docker permissions to take effect."
echo
echo "After logging back in, run:"
echo "  cd ~/VeloraTrajectories"
echo "  ./test_gemini_no_poetry.sh"
