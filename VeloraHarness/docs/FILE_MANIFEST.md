# VeloraHarness File Manifest

## Methodology: Static Import Analysis

Files were identified using **AST-based static import tracing**, an industry-standard technique:

```python
import ast
from collections import deque

def extract_imports(file_path):
    """Extract all import statements from a Python file."""
    with open(file_path, 'r') as f:
        tree = ast.parse(f.read())
    imports = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                imports.add(alias.name)
        elif isinstance(node, ast.ImportFrom):
            if node.module:
                imports.add(node.module)
    return imports

def trace_imports(start_file, project_root, target_prefix='openhands'):
    """Recursively trace all imports from entry point."""
    visited = set()
    to_process = deque([start_file])
    while to_process:
        current = to_process.popleft()
        if current in visited:
            continue
        visited.add(current)
        imports = extract_imports(current)
        for imp in imports:
            if imp.startswith(target_prefix):
                resolved = resolve_module_to_file(imp, project_root)
                if resolved:
                    to_process.append(resolved)
    return visited
```

### Entry Points Analyzed
1. `evaluation/benchmarks/multi_swe_bench/run_infer.py` - Trajectory generation
2. `evaluation/benchmarks/multi_swe_bench/eval_infer.py` - Patch evaluation

### Benefits of This Approach
- **Deterministic**: Same input always produces same output
- **Complete**: Catches all static imports (import X, from X import Y)
- **No runtime dependencies**: Works without installing packages
- **Reproducible**: Can re-run analysis if OpenHands changes

### Iterative Refinement
After initial static analysis, we tested imports on AWS and added missing files:
- Integration service files (bitbucket, github, gitlab, azure_devops)
- Agent tool files (loc_agent, readonly_agent)
- Runtime utility files

## Statistics

| Category | Count |
|----------|-------|
| Python files (openhands/*) | 321 |
| Jinja2 templates (*.j2) | 58 |
| Shell scripts (*.sh) | 3 |
| Evaluation scripts | 2 |
| Config files | 2 |
| **Total** | **386** |

## Directory Structure

```
VeloraHarness/
├── config.toml                 # LLM configurations (GPT, Claude, Kimi, Qwen)
├── pyproject.toml              # Poetry dependencies
├── requirements.txt            # Pip dependencies (alternative)
├── FILE_MANIFEST.md           # This file
│
├── openhands/                  # Core library (321 files)
│   ├── agenthub/              # Agents (CodeActAgent, BrowsingAgent, etc.)
│   │   ├── codeact_agent/     # Primary agent for code tasks
│   │   ├── browsing_agent/    # Web browsing agent
│   │   ├── loc_agent/         # Location-based agent
│   │   └── readonly_agent/    # Read-only agent
│   ├── controller/            # AgentController, State management
│   ├── core/                  # Config, Logger, Main loop
│   │   └── config/            # LLMConfig, AgentConfig, SandboxConfig
│   ├── events/                # Action/Observation events, serialization
│   ├── integrations/          # Git providers (GitHub, GitLab, BitBucket, Azure)
│   ├── io/                    # JSON handling
│   ├── llm/                   # LLM client with Kimi/Qwen fixes
│   ├── mcp/                   # MCP client
│   ├── memory/                # Condenser implementations
│   ├── microagent/            # Microagent system
│   ├── runtime/               # Docker runtime, builders, plugins
│   ├── security/              # Security analyzers
│   ├── server/                # Server services
│   ├── storage/               # File storage backends
│   └── utils/                 # Utilities
│
├── evaluation/
│   ├── benchmarks/
│   │   └── multi_swe_bench/
│   │       ├── run_infer.py   # Entry point for trajectory generation
│   │       ├── eval_infer.py  # Entry point for evaluation
│   │       └── scripts/
│   │           └── setup/
│   │               ├── instance_swe_entry.sh
│   │               └── swe_entry.sh
│   └── utils/
│       └── shared.py
│
├── data/
│   └── sample_task.jsonl      # Test dataset
│
└── scripts/
```

## Critical LLM Fixes Preserved

### openhands/llm/llm.py
- **Kimi K2 reasoning_content merge**: Merges `reasoning_content` into `content`
- **XML finish tag translation**: Converts Kimi's `<finish>` tags to tool calls
- **completion_kwargs support**: Custom LLM parameters
- **force_string_serializer**: For DeepSeek and Qwen models

### openhands/llm/model_features.py
- Pattern matching for model capabilities
- Function calling support detection for Kimi, Qwen

### openhands/llm/fn_call_converter.py
- String-based function calling for non-native models
- Tool call parsing from text responses

### openhands/llm/retry_mixin.py
- Exponential backoff retry logic
- LLMNoResponseError handling

## AWS Deployment

Deployed on AWS instance `18.234.114.70`:

```bash
# Connect
ssh -i velora-us.pem ubuntu@18.234.114.70

# Directory
cd ~/VeloraHarness

# Run with Poetry
poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent-cls CodeActAgent \
    --llm-config llm.gpt \
    --max-iterations 200 \
    --eval-num-workers 1 \
    --dataset data/sample_task.jsonl \
    --split train
```

## Usage

```bash
# Install dependencies
poetry install --no-root

# Or with pip
pip install -r requirements.txt

# Run trajectory generation
PYTHONPATH=. python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent-cls CodeActAgent \
    --llm-config llm.gpt \
    --max-iterations 200 \
    --dataset /path/to/dataset.jsonl \
    --split train

# Run evaluation
PYTHONPATH=. python evaluation/benchmarks/multi_swe_bench/eval_infer.py \
    --instance_id INSTANCE_ID \
    --output_dir ./outputs
```

## Verification Results

All core imports verified on AWS:
```
✓ LLM import OK
✓ OpenHandsConfig import OK
✓ CodeActAgent import OK
✓ DockerRuntime import OK
✓ AgentController import OK
✓ run_infer.py imports successful!
```
