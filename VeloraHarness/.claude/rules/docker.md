---
paths:
  - "openhands/runtime/**/*"
  - "**/*Dockerfile*"
  - "**/*.j2"
---

# Docker Runtime Build Rules

## Critical Environment Variables

Always set these before building:
```bash
export DOCKER_BUILDKIT=0  # Prevents buildx failures
export EVAL_DOCKER_IMAGE_PREFIX=mswebench
export USE_INSTANCE_IMAGE=true
```

## Amazon Linux 2023 Specific

### Avoid Poetry in Dockerfile
Poetry fails with Amazon Linux kernel version parsing. Use:
```dockerfile
# GOOD - works on all platforms
/openhands/bin/uv pip install --python /path/to/python -e .

# BAD - fails on Amazon Linux
poetry install
poetry run python ...
```

### Permission Fixes
Conda envs created as root need chown:
```dockerfile
RUN /openhands/micromamba/bin/micromamba create -n openhands -y && \
    chown -R openhands:openhands /openhands/micromamba
```

## Dockerfile.j2 Template

Key locations:
- Line 241-260: Playwright installation (use `python -m playwright`, not `poetry run`)
- Line 285-303: User openhands package installation (use uv)
- Line 329-332: Conda environment creation (add chown)

## Required Dummy Files

The build creates these to satisfy pyproject.toml:
```dockerfile
touch /openhands/code/README.md
mkdir -p /openhands/code/third_party && touch /openhands/code/third_party/__init__.py
```

## Testing Runtime Images

```bash
# List images
docker images | grep openhands/runtime

# Test dependencies
docker run --rm <image> python -c "import pydantic, openai; print('OK')"

# Check installed packages
docker run --rm <image> pip list | wc -l
# Should be ~350+ packages
```
