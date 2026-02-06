#!/bin/bash
#
# Setup Python Alias
#
# Creates a 'python' symlink to python3 for convenience
#

set -e

echo "Setting up Python alias..."

# Check if python3 exists
if ! command -v python3 &> /dev/null; then
    echo "Error: python3 not found. Please install Python 3 first."
    exit 1
fi

# Check if python already exists
if command -v python &> /dev/null; then
    PYTHON_VERSION=$(python --version 2>&1)
    echo "✓ 'python' command already exists: $PYTHON_VERSION"
    exit 0
fi

# Create symlink in user's local bin
mkdir -p ~/.local/bin
ln -sf $(which python3) ~/.local/bin/python

# Add to PATH if not already there
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
    export PATH="$HOME/.local/bin:$PATH"
    echo "✓ Added ~/.local/bin to PATH"
fi

echo "✓ Created symlink: ~/.local/bin/python -> $(which python3)"
echo
echo "Run this command to activate in current shell:"
echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
echo
echo "Or start a new shell session."
