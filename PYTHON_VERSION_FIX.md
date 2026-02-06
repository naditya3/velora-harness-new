# Python Version Issue - Solutions

## Problem

VeloraHarness requires **Python 3.10+** but your system has **Python 3.9.25**.

The code uses `match` statements (introduced in Python 3.10):
```python
match self.condenser.condensed_history(state):  # Syntax error in Python 3.9
```

## Solutions

### Option 1: Use Docker (Easiest & Recommended)

Run everything in a Docker container with Python 3.11:

```bash
cd ~/VeloraTrajectories
./run_with_docker.sh
```

This will:
- Build a Docker image with Python 3.11
- Install all dependencies
- Run trajectory generation
- Save results to `outputs/gemini_test/`

---

### Option 2: Upgrade Python (Complex)

If you have sudo access:

```bash
# Install Python 3.11 from source
sudo yum install -y gcc openssl-devel bzip2-devel libffi-devel

cd /tmp
wget https://www.python.org/ftp/python/3.11.9/Python-3.11.9.tgz
tar xzf Python-3.11.9.tgz
cd Python-3.11.9
./configure --enable-optimizations
make altinstall

# Use python3.11 instead of python3
python3.11 --version
```

Then update all scripts to use `python3.11` instead of `python3`.

---

### Option 3: Use pyenv (If available)

```bash
# Install pyenv
curl https://pyenv.run | bash

# Install Python 3.11
pyenv install 3.11.9
pyenv local 3.11.9

# Verify
python --version  # Should show 3.11.9
```

---

### Option 4: Use Conda/Miniconda

```bash
# Install Miniconda
wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh
bash Miniconda3-latest-Linux-aarch64.sh -b

# Create environment with Python 3.11
~/miniconda3/bin/conda create -n velora python=3.11 -y
~/miniconda3/bin/conda activate velora

# Install dependencies
pip install -r jaeger/VeloraHarness/requirements.txt
```

---

## Quick Test After Fix

Once Python 3.10+ is available:

```bash
# Verify Python version
python3 --version  # Must be 3.10+

# Test imports
cd ~/VeloraTrajectories/jaeger/VeloraHarness
python3 -c "from evaluation.benchmarks.multi_swe_bench import run_infer; print('✓ OK')"

# Run test
cd ~/VeloraTrajectories
./test_gemini_no_poetry.sh
```

---

## Why This Happened

VeloraHarness is based on OpenHands, which requires Python 3.11+ for:
- Pattern matching (`match` statements)
- Type hints improvements
- Performance optimizations

Amazon Linux 2023 ships with Python 3.9 by default, which is too old.

---

## Recommended: Docker Approach

**I recommend using Docker** because:
- ✅ No system Python changes
- ✅ Isolated environment
- ✅ Works immediately
- ✅ Same environment for all models
- ✅ Easy to reproduce

Just run:
```bash
cd ~/VeloraTrajectories
./run_with_docker.sh
```

This will handle everything automatically!
