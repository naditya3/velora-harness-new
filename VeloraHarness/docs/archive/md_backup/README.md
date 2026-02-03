# VeloraHarness

A standalone trajectory generation and evaluation harness extracted from [OpenHands](https://github.com/All-Hands-AI/OpenHands), optimized for Velora's multi-language SWE-bench evaluation pipeline.

## Overview

VeloraHarness provides two core capabilities:

1. **Trajectory Generation** - Run AI agents (CodeActAgent) against coding tasks to produce solution patches
2. **Multi-Language Evaluation** - Evaluate generated patches against test suites in Go, Java, Rust, Python, and C/C++

## Directory Structure

```
VeloraHarness/
├── README.md                # This file
├── config.toml              # LLM and agent configuration
├── config.toml.example      # Configuration template
├── requirements.txt         # Python dependencies
├── pyproject.toml           # Poetry dependencies
├── poetry.lock              # Dependency lock file
│
├── docs/                    # Documentation
│   ├── SETUP.md             # Setup and installation guide
│   ├── DEPLOYMENT.md        # AWS deployment guide
│   └── FILE_MANIFEST.md     # Complete file listing
│
├── openhands/               # Core OpenHands modules (extracted)
│   ├── agenthub/            # Agent implementations (CodeActAgent, etc.)
│   ├── controller/          # Agent controller and state management
│   ├── core/                # Configuration, logging, schema
│   ├── events/              # Event system (actions, observations)
│   ├── io/                  # File and I/O utilities
│   ├── llm/                 # LLM client with model-specific fixes
│   ├── memory/              # Conversation history management
│   ├── runtime/             # Docker runtime for code execution
│   ├── security/            # Security analyzers
│   └── utils/               # Utility functions
│
├── evaluation/              # Evaluation framework
│   ├── benchmarks/
│   │   ├── multi_swe_bench/ # Multi-language SWE-bench
│   │   ├── swe_bench/       # Original SWE-bench
│   │   └── client_tasks/    # Client-specific tasks
│   ├── utils/               # Evaluation utilities
│   └── velora3_eval_multilang.py  # Multi-language evaluator
│
├── scripts/                 # Utility scripts
│   ├── run_tasks_v2.sh      # Batch task runner
│   └── verify_aws_consistency.sh  # AWS instance verification
│
├── data/                    # Task datasets (JSONL format)
├── skills/                  # Agent skill definitions
└── .claude/                 # Claude AI project rules
```

## Quick Links

- [Setup Guide](docs/SETUP.md) - Installation and configuration
- [Deployment Guide](docs/DEPLOYMENT.md) - AWS deployment instructions
- [File Manifest](docs/FILE_MANIFEST.md) - Complete file listing and methodology

## Prerequisites

- Python 3.11+
- Docker
- Poetry (for dependency management)
- AWS credentials (for S3 access to Docker images)

## Installation

### Local Setup

```bash
cd VeloraHarness
pip install -r requirements.txt
```

### AWS Instance Setup

```bash
# Clone/copy VeloraHarness to instance
cd ~/VeloraHarness
poetry install

# Set required environment variables
export DOCKER_BUILDKIT=0
export EVAL_DOCKER_IMAGE_PREFIX=mswebench
export USE_INSTANCE_IMAGE=true
```

## Configuration

⚠️  **IMPORTANT**: The repository includes `config.toml` with placeholder API keys.

**Before running, you MUST add your actual API keys:**

```bash
# Edit config.toml and replace placeholders
nano config.toml  # or use your preferred editor
```

**Required API Keys:**
- `YOUR_OPENAI_API_KEY_HERE` → Your OpenAI API key
- `YOUR_ANTHROPIC_API_KEY_HERE` → Your Anthropic/Claude API key  
- `YOUR_MOONSHOT_API_KEY_HERE` → Your Moonshot/Kimi API key
- `YOUR_QWEN_API_KEY_HERE` → Your Qwen API key/endpoint

**Note:** `config.toml` is included in the repository (not gitignored) to simplify setup and avoid Poetry dependency issues. If you fork this repo, ensure you don't commit your actual API keys - replace them with placeholders before pushing.

### LLM Providers

```toml
[llm.gpt]
model = "gpt-4.1"
api_key = "your-api-key"

[llm.claude]
model = "claude-sonnet-4-5-20250929"
api_key = "your-api-key"

[llm.kimi]
model = "kimi-k2-0711-preview"
api_key = "your-api-key"
base_url = "https://api.moonshot.cn/v1"

[llm.qwen]
model = "qwen-max-0125"
api_key = "your-api-key"
```

### Sandbox Configuration

```toml
[sandbox]
runtime_container_image = "ghcr.io/openhands/runtime:velora_ready"
timeout = 300
```

## Usage

### 1. Trajectory Generation

Generate a trajectory for a coding task:

```bash
cd VeloraHarness
export PYTHONPATH="$(pwd):$PYTHONPATH"

poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent-cls CodeActAgent \
    --llm-config llm.gpt \
    --max-iterations 300 \
    --eval-num-workers 1 \
    --dataset data/task.jsonl \
    --split train \
    --eval-n-limit 1
```

**Parameters:**
- `--agent-cls`: Agent class to use (default: `CodeActAgent`)
- `--llm-config`: LLM configuration section from `config.toml`
- `--max-iterations`: Maximum agent iterations before stopping
- `--dataset`: Path to task dataset (JSONL format)
- `--eval-n-limit`: Number of tasks to process

### 2. Multi-Language Evaluation

Evaluate a generated trajectory:

```bash
python evaluation/velora3_eval_multilang.py \
    --trajectory-file outputs/trajectory.jsonl \
    --f2p-file data/f2p_tests.jsonl \
    --instance-id 1768293216544217 \
    --docker-image mswebench/task-image:latest \
    --output-file outputs/eval_output.jsonl \
    --timeout 600
```

**Parameters:**
- `--trajectory-file`: Path to generated trajectory
- `--f2p-file`: Path to FAIL_TO_PASS test definitions
- `--instance-id`: Velora instance ID
- `--docker-image`: Docker image with the codebase
- `--timeout`: Test execution timeout in seconds

## Task Dataset Format

Tasks are stored in JSONL format with the following structure:

```json
{
  "instance_id": "1768293216544217",
  "repo": "owner/repo",
  "base_commit": "abc123...",
  "problem_statement": "Description of the issue to fix...",
  "hints_text": "Optional hints...",
  "FAIL_TO_PASS": ["test1", "test2"],
  "PASS_TO_PASS": ["test3"],
  "test_command": "go test ./...",
  "language": "go",
  "image_storage_uri": "s3://bucket/images/task.tar"
}
```

## Docker Image Management

### Loading Task Images

```bash
# Download from S3
aws s3 cp s3://kuberha-velora/velora-files/images/task.tar /tmp/

# Load into Docker
docker load < /tmp/task.tar

# Tag for OpenHands (required dual tagging)
docker tag loaded_image:latest mswebench/sweb.eval.x86_64.instance_id:latest
docker tag loaded_image:latest mswebench/owner_m_repo:pr-instance_id
```

### Runtime Image

The harness uses a pre-built runtime image:
```
ghcr.io/openhands/runtime:velora_ready
```

This image includes `tmux` and the `/swe_util` directory required by OpenHands.

## Supported Languages

The multi-language evaluation supports:

| Language | Parser | Test Framework |
|----------|--------|----------------|
| Python | `parse_log_pytest_v3` | pytest |
| Go | `parse_log_go_test` | go test |
| Java | `parse_log_junit` | JUnit/Maven |
| Rust | `parse_log_cargo_test` | cargo test |
| C/C++ | `parse_log_meson`, `parse_log_make` | meson, make |

## LLM Model Support

The harness includes fixes for model-specific quirks:

- **Kimi**: Handles `reasoning_content` field and XML finish tags
- **Qwen/DeepSeek**: String serialization for tool parameters
- **Claude**: Native function calling support
- **GPT-4**: Standard OpenAI API

## Output Format

### Trajectory Output (`output.jsonl`)

```json
{
  "instance_id": "...",
  "test_result": {
    "git_patch": "diff --git a/...",
    "exit_code": 0
  },
  "history": [...],
  "metrics": {...},
  "instance": {...}
}
```

### Evaluation Output (`eval_output.jsonl`)

```json
{
  "instance_id": "...",
  "resolved": false,
  "fail_to_pass_success": [],
  "fail_to_pass_failed": ["test1", "test2"],
  "pass_to_pass_success": ["test3"],
  "pass_to_pass_failed": [],
  "test_output": "..."
}
```

## Methodology

This harness was created using **AST-based static import analysis** to extract only the essential files from the OpenHands repository:

1. Parse entry points (`run_infer.py`, `eval_infer.py`) using Python's AST module
2. Recursively trace all imports to build a complete dependency graph
3. Include all transitively imported modules
4. Copy Jinja2 templates and shell scripts referenced by the code

This ensures:
- **Completeness**: All necessary code is included
- **Minimality**: No unused code bloats the harness
- **Correctness**: Import paths remain valid

See `FILE_MANIFEST.md` for the complete list of included files.

## Troubleshooting

### Common Issues

1. **`tmux` not found in runtime**
   - Use the `velora_ready` runtime image or build one with tmux installed

2. **Docker image not found**
   - Ensure dual tagging of images (see Docker Image Management)

3. **`go mod tidy` failures**
   - Expected for older codebases with outdated dependencies
   - Tests may still run despite this warning

4. **Permission denied in `/swe_util`**
   - Runtime image needs correct permissions for `openhands` user

### Environment Variables

```bash
export DOCKER_BUILDKIT=0              # Prevents buildx failures
export EVAL_DOCKER_IMAGE_PREFIX=mswebench
export USE_INSTANCE_IMAGE=true
export PYTHONPATH="/path/to/VeloraHarness:$PYTHONPATH"
```

## License

This project is based on OpenHands, licensed under the MIT License.

## Related Projects

- [OpenHands](https://github.com/All-Hands-AI/OpenHands) - Original AI agent framework
- [SWE-bench](https://github.com/princeton-nlp/SWE-bench) - Software engineering benchmark
- [Multi-SWE-bench](https://github.com/multi-swe-bench/multi-swe-bench) - Multi-language extension

