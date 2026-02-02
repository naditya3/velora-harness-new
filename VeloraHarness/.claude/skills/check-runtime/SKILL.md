---
name: check-runtime
description: Check Docker runtime health and fix common issues
allowed-tools: Bash, Read
argument-hint: [image-name]
---

# Check Docker Runtime Health

Verify Docker runtime images are properly configured and dependencies are installed.

## Checks to Perform

### 1. List Runtime Images
```bash
docker images | grep -E "(openhands|runtime)" | head -10
```

### 2. Check Running Containers
```bash
docker ps | grep openhands
```

### 3. Verify Dependencies (if image specified: $ARGUMENTS)
```bash
IMAGE="${ARGUMENTS:-$(docker images --format '{{.Repository}}:{{.Tag}}' | grep openhands/runtime | head -1)}"
if [ -n "$IMAGE" ]; then
    echo "Testing image: $IMAGE"
    docker run --rm "$IMAGE" python -c "
import pydantic
import openai
import litellm
from openhands.core.config import AppConfig
print(f'pydantic: {pydantic.__version__}')
print(f'openai: {openai.__version__}')
print(f'litellm: {litellm.__version__}')
print('All critical dependencies OK!')
"
    echo ""
    echo "Package count:"
    docker run --rm "$IMAGE" pip list 2>/dev/null | wc -l
fi
```

### 4. Check Disk Space
```bash
df -h /var/lib/docker
docker system df
```

### 5. Clean Up Stale Images (if needed)
```bash
# List dangling images
docker images -f "dangling=true" -q

# To clean (manual):
# docker image prune -f
# docker container prune -f
```

## Common Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| Missing pydantic | pip install didn't run deps | Rebuild with uv |
| Permission denied | Conda env owned by root | Add chown in Dockerfile |
| Image too small (<7GB) | Dependencies missing | Check Dockerfile.j2 |
| Container exits immediately | Import error | Check docker logs |

## Report

Provide summary of:
- Number of runtime images
- Disk usage
- Any dependency issues found
- Recommended cleanup actions
