# Setup Instructions for Amazon Linux 2023

Your system is missing Python 3.11+ and Docker. Here's how to set everything up.

## Quick Setup (Recommended)

Run the automated setup script:

```bash
cd ~/VeloraTrajectories
sudo ./setup_environment.sh
```

This will:
1. ✅ Install Python 3.11
2. ✅ Install Docker
3. ✅ Configure Docker permissions
4. ✅ Set Python 3.11 as default

**After running, you MUST log out and log back in** for Docker permissions to work.

---

## Manual Setup (If you prefer)

### 1. Install Python 3.11

```bash
sudo dnf install -y python3.11 python3.11-pip python3.11-devel
sudo alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1
sudo alternatives --set python3 /usr/bin/python3.11

# Verify
python3 --version  # Should show 3.11.x
```

### 2. Install Docker

```bash
sudo dnf install -y docker
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker $USER

# Verify
sudo docker --version
```

**Important**: Log out and log back in for Docker group membership to take effect.

### 3. Verify Setup

```bash
# Check Python
python3 --version  # Must be 3.11+

# Check Docker
docker ps  # Should not show permission error

# Check pip
python3 -m pip --version
```

---

## After Setup is Complete

Once Python 3.11 and Docker are installed:

### Install Dependencies

```bash
cd ~/VeloraTrajectories/jaeger/VeloraHarness
python3 -m pip install --user -r requirements.txt
```

### Run the Test

```bash
cd ~/VeloraTrajectories
./test_gemini_no_poetry.sh
```

This will:
- Convert 2 sample tasks from CSV
- Generate trajectories using Gemini
- Save results to `outputs/gemini_test/`

---

## Troubleshooting

### "Permission denied" when running Docker

**Solution**: Log out and log back in for group permissions to take effect.

```bash
# Verify you're in the docker group
groups | grep docker
```

### "Module not found" errors

**Solution**: Install missing dependencies

```bash
cd ~/VeloraTrajectories/jaeger/VeloraHarness
python3 -m pip install --user -r requirements.txt
```

### Still getting syntax errors

**Solution**: Verify Python version

```bash
python3 --version  # Must show 3.11.x or higher

# If still showing 3.9, force set alternative
sudo alternatives --set python3 /usr/bin/python3.11
```

---

## Expected Timeline

- **Setup**: ~5 minutes
- **Log out/in**: ~1 minute
- **Install dependencies**: ~5 minutes
- **First test run**: ~10 minutes
- **Total**: ~20 minutes

---

## Alternative: Use Existing Python 3.11 Container

If you don't want to modify your system, you can use the OpenHands Docker container directly:

```bash
# Pull the runtime image (has Python 3.11)
docker pull ghcr.io/openhands/runtime:velora_ready

# Run inside container
docker run -it \
    -v ~/VeloraTrajectories:/workspace \
    ghcr.io/openhands/runtime:velora_ready \
    /bin/bash

# Inside container:
cd /workspace
python3 --version  # Should be 3.11+
```

---

## Quick Command Reference

```bash
# Setup environment
sudo ./setup_environment.sh

# Log out and back in
exit

# Install dependencies
cd ~/VeloraTrajectories/jaeger/VeloraHarness
python3 -m pip install --user -r requirements.txt

# Run test
cd ~/VeloraTrajectories
./test_gemini_no_poetry.sh

# Check results
cat outputs/gemini_test/output.jsonl | python3 -m json.tool
```

---

## Next Steps After Successful Test

Once you see trajectories generated successfully:

1. ✅ Get API keys for other models (Claude, Kimi, Qwen, GPT)
2. ✅ Add keys to `jaeger/VeloraHarness/config.toml`
3. ✅ Run full batch: `./generate_trajectories.sh data/tasks.jsonl 50 outputs/`
4. ✅ Evaluate: `./evaluate_trajectories.sh outputs data/tasks.jsonl mswebench`
5. ✅ Analyze: `python3 analyze_results.py --output-dir outputs/`

---

## Support

If you encounter issues:
1. Check Python version: `python3 --version` (must be 3.11+)
2. Check Docker: `docker ps`
3. Check logs: `tail -f outputs/gemini_test/test.log`
4. Verify Gemini API key in `jaeger/VeloraHarness/config.toml`
