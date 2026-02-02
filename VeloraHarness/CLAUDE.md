# VeloraHarness - OpenHands SWE-Bench Evaluation Framework

## Project Overview

VeloraHarness is a customized OpenHands evaluation harness for running SWE-bench multi-language benchmarks. It supports multiple LLM providers with advanced reasoning capabilities.

## Key Architecture

### LLM Providers Supported
- **GPT-5.2 Codex** (`llm.gpt_codex`) - Uses `previous_response_id` for xhigh reasoning
- **Gemini 3 Pro** (`llm.gemini`) - Uses `thinking_blocks` for thought_signature preservation
- **Claude** (`llm.claude`) - Standard liteLLM integration

### Critical Files
- `openhands/llm/llm.py` - LLM routing and conversation_id tracking
- `openhands/llm/gpt_responses_openai_direct.py` - Direct OpenAI SDK for Codex
- `openhands/core/message.py` - Message class with thinking_blocks field
- `openhands/memory/conversation_memory.py` - thinking_blocks extraction
- `openhands/runtime/utils/runtime_templates/Dockerfile.j2` - Runtime container template
- `openhands/runtime/utils/runtime_build.py` - Docker build context preparation
- `config.toml` - LLM and runtime configuration

### Evaluation Scripts
- `evaluation/benchmarks/multi_swe_bench/run_infer.py` - Trajectory generation
- `evaluation/benchmarks/multi_swe_bench/eval_infer.py` - Patch evaluation
- `evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh` - Full pipeline

## Platform-Specific Notes

### Amazon Linux 2023 Workarounds
1. **Poetry kernel version bug** - Use `uv pip install` instead of `poetry install`
2. **Permission issues** - Add `chown -R openhands:openhands /openhands/micromamba` after conda env creation
3. **BuildKit issues** - Always use `DOCKER_BUILDKIT=0`

### Environment Variables
```bash
export DOCKER_BUILDKIT=0
export EVAL_DOCKER_IMAGE_PREFIX=mswebench
export USE_INSTANCE_IMAGE=true
```

## Common Commands

### Run Trajectory Generation
```bash
poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent-cls CodeActAgent \
    --llm-config llm.gpt_codex \
    --max-iterations 300 \
    --eval-num-workers 1 \
    --dataset /path/to/task.jsonl \
    --split train \
    --eval-n-limit 1
```

### Check Docker Runtime Images
```bash
docker images | grep openhands/runtime
```

### Verify Dependencies in Container
```bash
docker exec <container> python -c "import pydantic, openai, litellm; print('OK')"
```

## Code Style

- Python 3.12+
- Use type hints for all function signatures
- Follow existing OpenHands patterns
- Keep backward compatibility with liteLLM path

## Testing Checklist

Before committing changes:
1. Test Docker runtime build: `DOCKER_BUILDKIT=0 docker build ...`
2. Verify container starts: `docker run --rm <image> python -c "import pydantic"`
3. Test trajectory generation with small dataset (1 task)
4. Check LLM completions directory for proper token usage

## Documentation

Key documentation in `docs/`:
- `GEMINI_THOUGHT_SIGNATURE_FIX.md` - Gemini 3 multi-turn function calling fix
- `GPT_CODEX_XHIGH_FIX.md` - GPT-5.2 Codex reasoning integration
- `DOCKER_BUILD_ISSUES.md` - Cross-platform Docker build guide
- `XHIGH_REASONING_PROCESS.md` - Step-by-step xhigh usage guide

## Import Reference

@docs/GEMINI_THOUGHT_SIGNATURE_FIX.md
@docs/GPT_CODEX_XHIGH_FIX.md
@docs/DOCKER_BUILD_ISSUES.md
