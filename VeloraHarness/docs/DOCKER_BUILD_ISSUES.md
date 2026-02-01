# Docker Runtime Image Build - Cross-Platform Setup

This document describes the cross-platform Docker build setup for OpenHands runtime images, covering both Ubuntu and Amazon Linux 2023.

## Platform Compatibility

| Platform | Status | Notes |
|----------|--------|-------|
| Ubuntu 20.04/22.04/24.04 | ✅ Supported | Primary development platform |
| Amazon Linux 2023 | ✅ Supported | Requires Poetry workarounds |
| Debian | ✅ Supported | Similar to Ubuntu |

## Summary of Issues & Solutions

| Issue | Root Cause | Fix | Platforms Affected |
|-------|------------|-----|-------------------|
| Missing Python dependencies | `pip install -e .` doesn't install deps with poetry-core backend | Use `uv pip install -e .` | All |
| Permission denied during pip install | Conda env created as root, pip runs as openhands user | Add `chown` after conda env creation | All |
| Poetry kernel version parsing failure | Kernel format `6.1.159-182.297.amzn2023.x86_64` incompatible | Bypass poetry with `uv` and direct Python | Amazon Linux 2023 |

---

## Issue 1: Missing Python Dependencies

### Symptom
```
ModuleNotFoundError: No module named 'pydantic'
```

When running the OpenHands runtime container, critical dependencies like `pydantic`, `openai`, `litellm` were missing.

### Root Cause
The Dockerfile was using:
```dockerfile
pip install --no-cache-dir -e .
```

With `poetry-core` as the build backend (specified in `pyproject.toml`), `pip install -e .` only installs the package in editable mode but **does NOT install dependencies** from pyproject.toml.

### Diagnosis
```bash
# Check what's installed
docker exec <container> pip list | wc -l
# Result: Only ~50 packages instead of 348

# Verify dependencies would be installed with uv
docker exec <container> uv pip install --dry-run -e .
# Result: Would install 348 packages
```

### Fix
Replace `pip install -e .` with `uv pip install -e .`:
```dockerfile
# File: openhands/runtime/utils/runtime_templates/Dockerfile.j2
# Line 298

# OLD (broken):
/openhands/micromamba/bin/micromamba run -n openhands pip install --no-cache-dir -e .

# NEW (working):
/openhands/micromamba/bin/micromamba run -n openhands /openhands/bin/uv pip install \
    --python /openhands/micromamba/envs/openhands/bin/python3.12 --no-cache -e .
```

### Why `uv` works
`uv` (Astral's fast Python package installer) properly reads `pyproject.toml` and installs all dependencies, including:
- Runtime dependencies from `[project.dependencies]`
- Optional dependencies from `[project.optional-dependencies]`

---

## Issue 2: Permission Denied During pip Install

### Symptom
```
error: failed to remove file /openhands/micromamba/envs/openhands/lib/python3.12/site-packages/anyio-4.12.1.dist-info/INSTALLER: Permission denied (os error 13)
```

### Root Cause
The Dockerfile has a USER directive mismatch:

1. **Lines 329-330** (as `root`): Creates conda environment
   ```dockerfile
   RUN /openhands/micromamba/bin/micromamba create -n openhands -y && \
       /openhands/micromamba/bin/micromamba install -n openhands -c conda-forge poetry python=3.12 -y
   ```

2. **Line 298** (as `openhands`): Installs packages with pip/uv
   ```dockerfile
   USER openhands
   RUN ... uv pip install -e .
   ```

The conda environment at `/openhands/micromamba/envs/openhands/` was owned by `root`, but pip/uv ran as `openhands` user and couldn't modify the site-packages.

### Fix
Add `chown` after conda environment creation:

```dockerfile
# File: openhands/runtime/utils/runtime_templates/Dockerfile.j2
# Lines 329-332

RUN /openhands/micromamba/bin/micromamba create -n openhands -y && \
    /openhands/micromamba/bin/micromamba install -n openhands -c conda-forge poetry python=3.12 -y && \
    # Fix permissions: conda env created as root, openhands user needs to pip install later
    chown -R openhands:openhands /openhands/micromamba
```

---

## Issue 3: Poetry Kernel Version Parsing Failure

### Symptom
```
Could not parse version constraint: 6.1.159-182.297.amzn2023.x86_64
```

Poetry fails when trying to parse the Amazon Linux 2023 kernel version format.

### Root Cause
Poetry uses the system's kernel version in certain operations (e.g., `poetry install`, `poetry export`). The Amazon Linux 2023 kernel version format:
```
6.1.159-182.297.amzn2023.x86_64
```
Contains characters (`.amzn2023.x86_64`) that Poetry's version parser cannot handle.

### Fix
Bypass Poetry entirely by using `uv pip install` with pyproject.toml:

```dockerfile
# WORKAROUND: Use uv to install from pyproject.toml (bypasses poetry.lock kernel version bug)
# Poetry install/export fails with "Could not parse version constraint: 6.1.159-182.297.amzn2023.x86_64"
/openhands/micromamba/bin/micromamba run -n openhands /openhands/bin/uv pip install \
    --python /openhands/micromamba/envs/openhands/bin/python3.12 --no-cache -e .
```

**Trade-off**: This installs from `pyproject.toml` rather than `poetry.lock`, so exact version pinning from the lock file is not used. In practice, `uv` still respects version constraints from pyproject.toml.

---

## Additional Build Considerations

### BuildKit Disabled
Build with BuildKit disabled for compatibility:
```bash
DOCKER_BUILDKIT=0 docker build ...
```

### Required Dummy Files
The build creates dummy files to satisfy pyproject.toml requirements:
```dockerfile
# Create dummy third_party directory (required by pyproject.toml packages include)
mkdir -p /openhands/code/third_party && touch /openhands/code/third_party/__init__.py

# Create dummy build_vscode.py that exits immediately (skip VSCode extension build)
printf '%s\n' '#!/usr/bin/env python3' 'import os' 'import sys' \
    'if os.environ.get("SKIP_VSCODE_BUILD"):' '    print("Skipping VSCode build")' '    sys.exit(0)' \
    > /openhands/code/build_vscode.py
```

### Force Rebuild After Fixes
If old images exist with the broken configuration, delete them to force rebuild:
```bash
# List runtime images
docker images | grep runtime

# Delete old images
docker rmi <image_id>

# Rebuild will use updated Dockerfile.j2
```

---

## Verification

After building, verify the image has correct dependencies:

```bash
# Enter the container
docker run -it --rm <image> bash

# Check critical dependencies
python3 -c "
import pydantic
import openai
import litellm
from openhands.core.config import AppConfig
print(f'pydantic: {pydantic.__version__}')
print(f'openai: {openai.__version__}')
print('All critical dependencies installed successfully!')
"

# Check total package count (should be ~350+)
pip list | wc -l
```

---

## Files Modified

1. **`openhands/runtime/utils/runtime_templates/Dockerfile.j2`**
   - Line 245: Changed `poetry run playwright install` to `python -m playwright install`
   - Line 259: Changed `poetry run python` to `python` (via micromamba run)
   - Line 298: Changed `pip install -e .` to `uv pip install -e .`
   - Lines 331-332: Added `chown -R openhands:openhands /openhands/micromamba`

---

## Cross-Platform Design Principles

### 1. Use `uv` Instead of `pip` for Editable Installs
```dockerfile
# Works on all platforms - properly installs dependencies from pyproject.toml
/openhands/bin/uv pip install --python /openhands/micromamba/envs/openhands/bin/python3.12 --no-cache -e .
```

### 2. Use Direct Python Execution Instead of `poetry run`
```dockerfile
# BAD: Fails on Amazon Linux
poetry run python -c "..."
poetry run playwright install

# GOOD: Works everywhere
/openhands/micromamba/bin/micromamba run -n openhands python -c "..."
/openhands/micromamba/bin/micromamba run -n openhands python -m playwright install
```

### 3. Fix Permissions After Conda Environment Creation
```dockerfile
# Conda env is created as root, but pip/uv runs as openhands user
RUN /openhands/micromamba/bin/micromamba create -n openhands -y && \
    /openhands/micromamba/bin/micromamba install -n openhands -c conda-forge poetry python=3.12 -y && \
    chown -R openhands:openhands /openhands/micromamba
```

### 4. Poetry is Installed but Not Used for Package Management
- Poetry is still installed via micromamba (some tools may depend on it)
- Package installation is done via `uv` which reads `pyproject.toml`
- This avoids Poetry's kernel version parsing issues on Amazon Linux

---

## Why This Approach Works

| Component | Ubuntu | Amazon Linux 2023 |
|-----------|--------|-------------------|
| `uv pip install` | ✅ | ✅ |
| `micromamba run -n openhands python` | ✅ | ✅ |
| `poetry run python` | ✅ | ❌ (kernel parse error) |
| `poetry install` | ✅ | ❌ (kernel parse error) |

By using `uv` and `micromamba run` instead of `poetry run`, the build process works identically on both platforms.

---

## Summary

The core issue was a mismatch between:
1. The build backend (`poetry-core`) which requires a dependency-aware installer
2. The installer used (`pip`) which doesn't install dependencies for editable installs with poetry-core
3. File ownership between the conda environment creation (root) and package installation (openhands user)
4. Poetry's kernel version parser failing on non-standard kernel version formats

The fix uses `uv` for package installation and `micromamba run` for Python execution, which work correctly on all platforms.
