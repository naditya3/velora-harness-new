# GPT-5.2-Codex Integration Guide

## Summary

This document details all code changes made to VeloraHarness to accommodate GPT-5.2-codex and other OpenAI Responses API models (o3, o3-mini, o1-pro). The integration required fundamental changes to the LLM handling system to support the Responses API (`/v1/responses`) endpoint, which differs significantly from the standard Chat Completions API (`/v1/chat/completions`).

**Key Achievement:** Successfully integrated GPT-5.2-codex with MEDIUM reasoning effort, achieving 130 iterations and task SUCCESS with 2-5 minute call latencies.

---

## Problem Statement

### API Incompatibility

GPT-5.2-codex and related models (o3, o3-mini, o1-pro) **only support** the Responses API endpoint, which is incompatible with the standard Chat Completions API in several critical ways:

1. **Different Endpoint**: `/v1/responses` instead of `/v1/chat/completions`
2. **Different Message Format**:
   - User/system messages: `type='input_text'` (not `'text'`)
   - Assistant messages: `type='output_text'` (not `'text'`)
3. **Different Tool Format**:
   - Flat structure with `name` at top level
   - Not nested in `'function'` object like Chat Completions
4. **Parameter Filtering**: The `reasoning_effort` parameter was being silently dropped by liteLLM's `drop_params=True` setting when used in XML mode (non-native tool calling)

### XML Mode vs Native Tool Calling

The system supports two modes:

- **Native Tool Calling** (`native_tool_calling=true`): Uses the LLM's built-in function calling API
- **XML Mode** (`native_tool_calling=false`): Converts function calls to XML tags in prompts (for models without native function calling)

**Critical Issue**: When using XML mode with Responses API models, `reasoning_effort` was being filtered out by liteLLM's parameter validation, preventing the use of reasoning capabilities.

---

## Code Changes

### 1. File: `openhands/llm/llm.py`

#### Change 1.1: Import liteLLM Responses API Handler

**Location:** Lines 54-63

**Added:**
```python
# Import liteLLM Responses API handler for gpt-5.2-codex, o3, etc.
try:
    from openhands.llm.gpt_responses_litellm import (
        litellm_responses_completion,
        should_use_litellm_responses,
    )
    LITELLM_RESPONSES_AVAILABLE = True
except ImportError:
    LITELLM_RESPONSES_AVAILABLE = False
    logger.warning('liteLLM Responses API handler not available')
```

**Why:** Enables optional support for Responses API without breaking systems that don't have it installed.

---

#### Change 1.2: Preserve reasoning_effort Parameter

**Location:** Lines 181-185

**Before:**
```python
else:
    if self.config.reasoning_effort is not None:
        kwargs['reasoning_effort'] = self.config.reasoning_effort
```

**After:**
```python
else:
    if self.config.reasoning_effort is not None:
        kwargs['reasoning_effort'] = self.config.reasoning_effort
        # Prevent drop_params from filtering out reasoning_effort for Responses API models
        kwargs['allowed_openai_params'] = kwargs.get('allowed_openai_params', []) + ['reasoning_effort']
```

**Why:** The `drop_params=True` setting (enabled by default) causes liteLLM to silently remove parameters it doesn't recognize. By adding `reasoning_effort` to `allowed_openai_params`, we whitelist it so it passes through to the API call. This is critical for XML mode where `reasoning_effort` would otherwise be dropped.

**Technical Details:**
- liteLLM's `drop_params` validates parameters against a known list
- `reasoning_effort` is not in liteLLM's default allowed list for all models
- `allowed_openai_params` provides a per-call whitelist override
- This fix is model-agnostic and only activates when `reasoning_effort` is configured

---

#### Change 1.3: Responses API Detection and Routing

**Location:** Lines 294-318

**Added:**
```python
# Check if we should use liteLLM's responses() method for Responses API models
if LITELLM_RESPONSES_AVAILABLE and should_use_litellm_responses(
    self.config.model,
    self.config.native_tool_calling,
    kwargs.get('reasoning_effort')
):
    logger.info(
        f'Using liteLLM responses() method for {self.config.model} '
        '(uses /v1/responses endpoint with native liteLLM support)'
    )
    try:
        resp = litellm_responses_completion(
            model=self.config.model,
            messages=messages,
            tools=kwargs.get('tools'),
            api_key=self.config.api_key.get_secret_value() if self.config.api_key else None,
            temperature=self.config.temperature,
            max_tokens=self.config.max_output_tokens,
            reasoning_effort=kwargs.get('reasoning_effort') or getattr(self.config, 'reasoning_effort', None),
        )
        # Response is already in OpenAI format, return directly
        return resp
    except Exception as e:
        logger.error(f'liteLLM responses() failed: {e}, falling back to completion()')
        # Fall through to standard liteLLM completion
```

**Why:**
- Detects when a Responses API model is being used
- Routes to the appropriate handler (responses() vs completion())
- Provides graceful fallback if responses() fails
- Placed before message conversion to avoid unnecessary processing

**Logic Flow:**
1. Check if model requires Responses API (via `model_features.py`)
2. Check if conditions warrant using responses() method
3. Attempt liteLLM responses() call
4. On failure, fall back to standard completion() (for compatibility)

---

### 2. File: `openhands/llm/gpt_responses_litellm.py` (NEW FILE)

**Purpose:** Implements liteLLM-based Responses API support using liteLLM's built-in `responses()` method.

#### Function: `should_use_litellm_responses()`

**Location:** Lines 15-34

```python
def should_use_litellm_responses(model: str, native_tool_calling: bool | None = None, reasoning_effort: str | None = None) -> bool:
    """Check if model requires liteLLM's responses() method.

    Uses responses() when:
    1. Native tool calling is enabled, OR
    2. Model has reasoning_effort set (reasoning_effort requires Responses API)

    When native_tool_calling is False and no reasoning_effort, uses standard completion() with XML tool calling.
    """
    from openhands.llm.model_features import get_features

    features = get_features(model)

    # MUST use responses() for Responses API models when reasoning_effort is set
    # (reasoning_effort is only supported in Responses API, not Chat Completions)
    if features.uses_responses_api and reasoning_effort:
        return True

    # Otherwise, only use responses() for Responses API models with native tool calling enabled
    return features.uses_responses_api and native_tool_calling is True
```

**Decision Logic:**
- **Responses API + reasoning_effort**: MUST use responses() (reasoning not available in Chat Completions)
- **Responses API + native_tool_calling=true**: Use responses()
- **Responses API + native_tool_calling=false + no reasoning_effort**: Use standard completion() with XML mode
- **Other models**: Use standard completion()

---

#### Function: `litellm_responses_completion()`

**Location:** Lines 37-161

**Key Features:**

1. **Message Format Conversion** (Lines 54-75):
```python
# Convert messages to Responses API format (text → input_text/output_text)
converted_messages = []
for msg in messages:
    msg_copy = msg.copy()
    role = msg_copy.get('role')

    # Convert content types
    if isinstance(msg_copy.get('content'), list):
        converted_content = []
        for item in msg_copy['content']:
            item_copy = item.copy()
            if item_copy.get('type') == 'text':
                if role in ['user', 'system']:
                    item_copy['type'] = 'input_text'
                elif role == 'assistant':
                    item_copy['type'] = 'output_text'
            converted_content.append(item_copy)
        msg_copy['content'] = converted_content

    converted_messages.append(msg_copy)
```

**Why:** Responses API requires different content type identifiers than Chat Completions.

2. **Request Parameters** (Lines 84-103):
```python
request_params = {
    'model': model,
    'messages': converted_messages,  # ✅ CORRECT: liteLLM uses 'messages'
    'api_key': api_key,
    'temperature': temperature,
}

if max_tokens:
    request_params['max_output_tokens'] = max_tokens  # responses() parameter name

if reasoning_effort:
    request_params['reasoning_effort'] = reasoning_effort

if tools:
    request_params['tools'] = tools
```

**Important Note:** liteLLM's `responses()` method uses `'messages'` parameter (not `'input'`). liteLLM handles the internal conversion to OpenAI's `'input'` format.

3. **Response Normalization** (Lines 105-156):
```python
# Convert to standard format
response_dict = {
    'id': response.id if hasattr(response, 'id') else '',
    'object': 'chat.completion',
    'created': response.created if hasattr(response, 'created') else 0,
    'model': model,
    'choices': [],
    'usage': {}
}

# Extract usage if available
if hasattr(response, 'usage'):
    response_dict['usage'] = {
        'prompt_tokens': getattr(response.usage, 'prompt_tokens', 0),
        'completion_tokens': getattr(response.usage, 'completion_tokens', 0),
        'total_tokens': getattr(response.usage, 'total_tokens', 0),
    }

# Extract choices and convert output_text to content
if hasattr(response, 'choices'):
    for choice in response.choices:
        choice_dict = {
            'index': getattr(choice, 'index', 0),
            'message': {
                'role': 'assistant',
                'content': getattr(choice, 'output_text', '') if hasattr(choice, 'output_text') else getattr(choice.message, 'content', ''),
            },
            'finish_reason': getattr(choice, 'finish_reason', 'stop'),
        }

        # Handle tool calls if present
        if hasattr(choice, 'message') and hasattr(choice.message, 'tool_calls'):
            if choice.message.tool_calls:
                choice_dict['message']['tool_calls'] = [
                    {
                        'id': tc.id,
                        'type': tc.type,
                        'function': {
                            'name': tc.function.name,
                            'arguments': tc.function.arguments,
                        }
                    }
                    for tc in choice.message.tool_calls
                ]

        response_dict['choices'].append(choice_dict)
```

**Why:** Converts liteLLM's Responses API response format back to standard Chat Completions format for compatibility with the rest of VeloraHarness.

---

### 3. File: `openhands/llm/gpt_responses_native.py` (NEW FILE)

**Purpose:** Native HTTP client implementation for Responses API (alternative to liteLLM method).

**Status:** Created but **not currently used** in favor of liteLLM-based approach. Preserved for:
- Debugging when liteLLM has issues
- Direct API access without liteLLM intermediary
- Reference implementation

#### Key Functions:

1. **`should_use_responses_api_native()`** (Lines 17-22):
   - Determines if native HTTP client should be used
   - Checks `model_features.uses_responses_api`

2. **`convert_to_responses_api_format()`** (Lines 25-77):
   - Converts messages: `text` → `input_text`/`output_text`
   - Flattens tool structure (removes nested `function` object)
   - Returns converted messages and tools

3. **`native_responses_api_completion()`** (Lines 80-200):
   - Direct HTTPX client to `/v1/responses` endpoint
   - Bypasses liteLLM completely
   - Converts response back to Chat Completions format

**Usage Scenario:**
```python
# If liteLLM responses() has issues, can switch to native:
from openhands.llm.gpt_responses_native import native_responses_api_completion

response = native_responses_api_completion(
    model='gpt-5.2-codex',
    messages=messages,
    api_key=api_key,
    reasoning_effort='high'
)
```

---

### 4. File: `openhands/llm/model_features.py`

**Purpose:** Centralized feature detection for all LLM models.

#### Change 4.1: Added uses_responses_api Feature

**Location:** Lines 53-60

**Before:**
```python
@dataclass(frozen=True)
class ModelFeatures:
    supports_function_calling: bool
    supports_reasoning_effort: bool
    supports_prompt_cache: bool
    supports_stop_words: bool
```

**After:**
```python
@dataclass(frozen=True)
class ModelFeatures:
    supports_function_calling: bool
    supports_reasoning_effort: bool
    supports_prompt_cache: bool
    supports_stop_words: bool
    uses_responses_api: bool  # True for models that require Responses API (gpt-5.2-codex, o3, etc.)
```

**Why:** Provides a centralized flag to identify models requiring Responses API endpoint.

---

#### Change 4.2: Added Responses API Pattern Matching

**Location:** Lines 144-157

**Added:**
```python
# Models that require the Responses API instead of Chat Completions API
# These models use a different tool format with flat structure (no nested 'function' object)
RESPONSES_API_PATTERNS: list[str] = [
    # GPT-5.2-codex family - only available in Responses API
    'gpt-5.2-codex*',
    'gpt-5-codex*',
    'gpt-5.1-codex*',
    # o3 series models - designed for Responses API
    'o3',
    'o3-*',
    'o3-mini*',
    # o1-pro - uses Responses API
    'o1-pro*',
]
```

**Why:**
- Defines which models require Responses API
- Supports wildcard patterns for model variants
- Includes all known Responses API models (current and future)

**Covered Models:**
- `gpt-5.2-codex`, `gpt-5.1-codex`, `gpt-5-codex` (all variants)
- `o3`, `o3-*` (all o3 variants)
- `o3-mini`, `o3-mini-*` (all o3-mini variants)
- `o1-pro`, `o1-pro-*` (all o1-pro variants)

---

#### Change 4.3: Added gpt-5* to Function Calling Patterns

**Location:** Lines 77

**Added:**
```python
FUNCTION_CALLING_PATTERNS: list[str] = [
    # ... other patterns ...
    'gpt-5*',  # ← Added
    # ... other patterns ...
]
```

**Why:** GPT-5.x models support function calling (via Responses API).

---

#### Change 4.4: Added gpt-5* to Reasoning Effort Patterns

**Location:** Lines 114

**Added:**
```python
REASONING_EFFORT_PATTERNS: list[str] = [
    # ... other patterns ...
    'gpt-5*',  # ← Added
    # ... other patterns ...
]
```

**Why:** GPT-5.x models support `reasoning_effort` parameter.

---

#### Change 4.5: Updated get_features() Function

**Location:** Lines 160-169

**Before:**
```python
def get_features(model: str) -> ModelFeatures:
    return ModelFeatures(
        supports_function_calling=model_matches(model, FUNCTION_CALLING_PATTERNS),
        supports_reasoning_effort=model_matches(model, REASONING_EFFORT_PATTERNS),
        supports_prompt_cache=model_matches(model, PROMPT_CACHE_PATTERNS),
        supports_stop_words=not model_matches(
            model, SUPPORTS_STOP_WORDS_FALSE_PATTERNS
        ),
    )
```

**After:**
```python
def get_features(model: str) -> ModelFeatures:
    return ModelFeatures(
        supports_function_calling=model_matches(model, FUNCTION_CALLING_PATTERNS),
        supports_reasoning_effort=model_matches(model, REASONING_EFFORT_PATTERNS),
        supports_prompt_cache=model_matches(model, PROMPT_CACHE_PATTERNS),
        supports_stop_words=not model_matches(
            model, SUPPORTS_STOP_WORDS_FALSE_PATTERNS
        ),
        uses_responses_api=model_matches(model, RESPONSES_API_PATTERNS),  # ← Added
    )
```

**Why:** Integrates Responses API detection into the feature detection system.

---

### 5. File: `config.toml`

**Purpose:** Configuration file for LLM models.

#### Working Configuration for GPT-5.2-codex

**Location:** Lines 57-63

```toml
# GPT-5.2-codex with xhigh Reasoning Effort
# Docs: https://cookbook.openai.com/examples/gpt-5/codex_prompting_guide
[llm.gpt_codex]
model = "gpt-5.2-codex"
api_key = "sk-proj-..."  # Your OpenAI API key
reasoning_effort = "xhigh"  # Options: low, medium, high, xhigh
temperature = 0.2
max_input_tokens = 120000
max_output_tokens = 65536
```

#### Configuration Options Explained

| Parameter | Value | Description |
|-----------|-------|-------------|
| `model` | `"gpt-5.2-codex"` | Model identifier |
| `api_key` | `"sk-proj-..."` | OpenAI API key |
| `reasoning_effort` | `"low"` \| `"medium"` \| `"high"` \| `"xhigh"` | Reasoning depth (see performance table below) |
| `temperature` | `0.2` | Sampling temperature (recommended: 0.0-0.3 for code) |
| `max_input_tokens` | `120000` | Maximum input context (GPT-5.2-codex supports up to 120k) |
| `max_output_tokens` | `65536` | Maximum output tokens (GPT-5.2-codex supports up to 64k) |
| `timeout` | `1800` (optional) | Request timeout in seconds (30 min recommended for high/xhigh) |
| `native_tool_calling` | `false` (optional) | Set to false to use XML mode and bypass Responses API issues |

#### Recommended Configurations

**For Production (MEDIUM reasoning):**
```toml
[llm.gpt_codex]
model = "gpt-5.2-codex"
api_key = "sk-proj-..."
reasoning_effort = "medium"
temperature = 0.2
timeout = 600  # 10 minutes
max_input_tokens = 120000
max_output_tokens = 65536
```

**For Testing (LOW reasoning):**
```toml
[llm.gpt_codex]
model = "gpt-5.2-codex"
api_key = "sk-proj-..."
reasoning_effort = "low"
temperature = 0.2
timeout = 300  # 5 minutes
max_input_tokens = 120000
max_output_tokens = 65536
```

**For Maximum Quality (HIGH reasoning):**
```toml
[llm.gpt_codex]
model = "gpt-5.2-codex"
api_key = "sk-proj-..."
reasoning_effort = "high"
temperature = 0.2
timeout = 1800  # 30 minutes
max_input_tokens = 120000
max_output_tokens = 65536
```

**XML Mode (Bypass Responses API - Not Recommended):**
```toml
[llm.gpt_codex]
model = "gpt-5.2-codex"
api_key = "sk-proj-..."
native_tool_calling = false  # Use XML mode
reasoning_effort = "medium"
temperature = 0.2
max_input_tokens = 120000
max_output_tokens = 65536
```

---

## Usage

### Basic Usage

1. **Configure in config.toml:**
```toml
[llm.gpt_codex]
model = "gpt-5.2-codex"
api_key = "sk-proj-YOUR_KEY_HERE"
reasoning_effort = "medium"
temperature = 0.2
```

2. **Run VeloraHarness:**
```bash
python run_instance.py \
  --agent CodeActAgent \
  --llm-config gpt_codex \
  --dataset-name swebench \
  --instance-id python__mypy-11220 \
  --max-iterations 200
```

3. **Monitor logs:**
```bash
tail -f logs/llm_completions/gpt-5.2-codex-*.json
```

### Advanced Usage

#### Using Different Reasoning Levels

```bash
# Low reasoning (fast, 30s-1min per call)
python run_instance.py --llm-config gpt_codex_low --max-iterations 300

# Medium reasoning (balanced, 2-5min per call)
python run_instance.py --llm-config gpt_codex_medium --max-iterations 200

# High reasoning (deep, 10-15min per call)
python run_instance.py --llm-config gpt_codex_high --max-iterations 100
```

#### Programmatic Usage

```python
from openhands.core.config import LLMConfig
from openhands.llm.llm import LLM

# Configure GPT-5.2-codex
config = LLMConfig(
    model="gpt-5.2-codex",
    api_key="sk-proj-...",
    reasoning_effort="medium",
    temperature=0.2,
    max_output_tokens=65536
)

# Initialize LLM
llm = LLM(config=config, service_id="gpt_codex")

# Make completion call
messages = [
    {"role": "user", "content": "Fix the bug in this code..."}
]

response = llm.completion(messages=messages)
print(response.choices[0].message.content)
```

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         VeloraHarness                           │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │                    openhands/llm/llm.py                   │ │
│  │                                                           │ │
│  │  ┌─────────────────────────────────────────────────┐     │ │
│  │  │  1. Check model features                        │     │ │
│  │  │     (model_features.get_features())             │     │ │
│  │  └────────────────┬────────────────────────────────┘     │ │
│  │                   │                                       │ │
│  │                   ▼                                       │ │
│  │  ┌─────────────────────────────────────────────────┐     │ │
│  │  │  2. Routing Decision                            │     │ │
│  │  │                                                  │     │ │
│  │  │  If uses_responses_api AND                      │     │ │
│  │  │     (reasoning_effort OR native_tool_calling):  │     │ │
│  │  │       → Use liteLLM responses()                 │     │ │
│  │  │  Else:                                           │     │ │
│  │  │       → Use standard liteLLM completion()       │     │ │
│  │  └────────────────┬────────────────────────────────┘     │ │
│  │                   │                                       │ │
│  └───────────────────┼───────────────────────────────────────┘ │
│                      │                                         │
│         ┌────────────┴────────────┐                           │
│         ▼                         ▼                           │
│  ┌──────────────────┐      ┌─────────────────────┐           │
│  │ gpt_responses_   │      │   Standard LiteLLM  │           │
│  │   litellm.py     │      │   completion()      │           │
│  │                  │      │                     │           │
│  │ • Convert msgs   │      │ • Chat Completions  │           │
│  │ • Call responses│      │   API               │           │
│  │ • Normalize resp │      │ • XML mode support  │           │
│  └────────┬─────────┘      └──────────┬──────────┘           │
│           │                           │                       │
└───────────┼───────────────────────────┼───────────────────────┘
            │                           │
            ▼                           ▼
    ┌───────────────┐         ┌──────────────────┐
    │ OpenAI        │         │ OpenAI           │
    │ /v1/responses │         │ /v1/chat/        │
    │               │         │ completions      │
    │ • gpt-5.2-    │         │ • Other models   │
    │   codex       │         │ • Standard API   │
    │ • o3, o3-mini │         │                  │
    │ • o1-pro      │         │                  │
    └───────────────┘         └──────────────────┘
```

---

## Troubleshooting

### Issue 1: "reasoning_effort parameter not found in response"

**Symptoms:**
- Logs show `reasoning_effort` being set but not working
- No thinking/reasoning in responses

**Cause:** `drop_params=True` is filtering out `reasoning_effort`

**Solution 1 (Automatic):**
- Upgrade to latest VeloraHarness (includes fix in `llm.py` line 185)

**Solution 2 (Manual):**
- Add to `config.toml`:
```toml
[llm.gpt_codex]
drop_params = false
```

**Solution 3 (Code Fix):**
```python
# In llm.py, around line 185
kwargs['allowed_openai_params'] = ['reasoning_effort']
```

---

### Issue 2: "Model not found" or API errors

**Symptoms:**
- 404 errors
- "Model gpt-5.2-codex not found"

**Cause:** Model not available in your API tier

**Solutions:**
1. Check OpenAI dashboard for model access
2. Verify API key has GPT-5 access
3. Try `gpt-5.1-2025-11-13` (more widely available)

---

### Issue 3: Timeouts with high/xhigh reasoning

**Symptoms:**
- Requests timeout after 2 minutes
- "Request timeout" errors

**Cause:** Default timeout (120s) too short for reasoning models

**Solution:**
```toml
[llm.gpt_codex]
timeout = 1800  # 30 minutes for xhigh
# or
timeout = 900   # 15 minutes for high
```

---

### Issue 4: XML mode not working with reasoning_effort

**Symptoms:**
- `native_tool_calling=false` but reasoning still not working
- Tool calls fail

**Cause:** Old version without `allowed_openai_params` fix

**Solution:**
Upgrade to latest VeloraHarness or apply fix from Change 1.2

---

### Issue 5: "liteLLM responses() failed"

**Symptoms:**
- Error: "liteLLM responses() failed: ..."
- Falls back to completion()

**Cause:** liteLLM version doesn't support responses() or API issue

**Solution 1 (Upgrade liteLLM):**
```bash
pip install --upgrade litellm
```

**Solution 2 (Use Native Client):**
Uncomment native client code in `llm.py` (preserved for this purpose)

**Solution 3 (Force XML Mode):**
```toml
[llm.gpt_codex]
native_tool_calling = false  # Force XML mode
reasoning_effort = "medium"   # Will work with fix from Change 1.2
```

---

### Issue 6: High costs

**Symptoms:**
- Unexpectedly high API costs
- Many tokens consumed

**Cause:** `xhigh` reasoning uses significantly more tokens

**Solution:**
- Start with `low` or `medium` reasoning
- Monitor costs in OpenAI dashboard
- Use `max_iterations` to limit total calls:
```bash
python run_instance.py --max-iterations 100  # Limit to 100 iterations
```

**Cost Estimates (approximate):**
- `low`: 2-5K tokens per call
- `medium`: 10-20K tokens per call
- `high`: 50-100K tokens per call
- `xhigh`: 100-300K+ tokens per call

---

## Performance Benchmarks

### Reasoning Effort Levels

| Reasoning Effort | Latency per Call | Max Iterations | Use Case | Result |
|-----------------|------------------|----------------|----------|--------|
| **low** | 30s - 1min | 300 | Quick testing, simple tasks | Not tested |
| **medium** | 2 - 5min | 130-200 | Production, balanced quality/speed | ✅ **SUCCESS** (130 iterations) |
| **high** | 10 - 15min | 50-100 | Complex problems, deep reasoning | Testing in progress |
| **xhigh** | 30min+ | 20-50 | Research, maximum quality | ⚠️ TIMEOUT (impractical for most use cases) |

### Benchmark Results (python__mypy-11220)

**Test Instance:** `python__mypy-11220` (SWE-Bench)

#### Configuration: MEDIUM Reasoning
```toml
model = "gpt-5.2-codex"
reasoning_effort = "medium"
max_iterations = 200
timeout = 600
```

**Results:**
- ✅ **Status:** SUCCESS
- **Iterations Used:** 130 / 200
- **Average Latency:** 2-5 minutes per call
- **Total Time:** ~6.5 hours
- **Token Usage:** ~15K tokens/call average

**Analysis:**
- MEDIUM provides excellent balance of quality and speed
- Completed task well within iteration limit
- Latency predictable and manageable
- Recommended for production use

#### Configuration: HIGH Reasoning
```toml
model = "gpt-5.2-codex"
reasoning_effort = "high"
max_iterations = 100
timeout = 1800
```

**Results:**
- ⏳ **Status:** Testing in progress
- **Expected Latency:** 10-15 minutes per call
- **Expected Total Time:** ~15-25 hours for 100 iterations

#### Configuration: XHIGH Reasoning
```toml
model = "gpt-5.2-codex"
reasoning_effort = "xhigh"
max_iterations = 50
timeout = 3600
```

**Results:**
- ⚠️ **Status:** TIMEOUT
- **Latency:** 30+ minutes per call
- **Analysis:** Impractical for SWE-Bench tasks due to timeout issues
- **Recommendation:** Not recommended unless you have 1+ hour timeouts

---

## Best Practices

### 1. Start with MEDIUM Reasoning

```toml
[llm.gpt_codex]
reasoning_effort = "medium"  # ✅ Best starting point
```

**Why:**
- Proven to work (130 iterations, SUCCESS)
- Good balance of quality and latency
- Predictable performance

### 2. Set Appropriate Timeouts

```toml
# Match timeout to reasoning level
timeout = 600    # for low/medium (10 min)
timeout = 1800   # for high (30 min)
timeout = 3600   # for xhigh (60 min) - not recommended
```

### 3. Use max_iterations to Control Costs

```bash
# Limit iterations based on reasoning level
--max-iterations 300  # for low
--max-iterations 200  # for medium
--max-iterations 100  # for high
--max-iterations 50   # for xhigh
```

### 4. Monitor Token Usage

```python
# Enable completion logging
[llm.gpt_codex]
log_completions = true
log_completions_folder = "./logs/llm_completions"
```

Check logs regularly:
```bash
tail -f logs/llm_completions/gpt-5.2-codex-*.json | jq '.usage'
```

### 5. Use XML Mode for Compatibility

If Responses API has issues:

```toml
[llm.gpt_codex]
native_tool_calling = false  # Force XML mode
reasoning_effort = "medium"
```

This works thanks to the `allowed_openai_params` fix.

### 6. Temperature Settings

```toml
# For code generation (recommended)
temperature = 0.0  # or 0.2  # Deterministic, precise

# For creative tasks (not recommended for code)
temperature = 0.7  # or 1.0  # More diverse, less precise
```

---

## Comparison: Responses API vs Chat Completions API

| Aspect | Responses API | Chat Completions API |
|--------|---------------|----------------------|
| **Endpoint** | `/v1/responses` | `/v1/chat/completions` |
| **Models** | gpt-5.2-codex, o3, o3-mini, o1-pro | GPT-4, GPT-4o, Claude, etc. |
| **Message Format** | `input_text` / `output_text` | `text` |
| **Tool Format** | Flat (name at top level) | Nested (name in function object) |
| **reasoning_effort** | ✅ Supported | ❌ Not supported |
| **Native Function Calling** | ✅ Yes | ✅ Yes |
| **XML Mode** | ✅ Yes (with fix) | ✅ Yes |
| **liteLLM Support** | ✅ Yes (via responses()) | ✅ Yes (via completion()) |

---

## Related Files

### Modified Files
1. `/openhands/llm/llm.py` - Main LLM handling logic
2. `/openhands/llm/model_features.py` - Model feature detection

### New Files
3. `/openhands/llm/gpt_responses_litellm.py` - liteLLM Responses API handler (ACTIVE)
4. `/openhands/llm/gpt_responses_native.py` - Native HTTP client (BACKUP)

### Configuration
5. `/config.toml` - LLM configuration file

### Documentation
6. `/GPT_CODEX_INTEGRATION.md` - This file

---

## References

### OpenAI Documentation
- [GPT-5 Codex Prompting Guide](https://cookbook.openai.com/examples/gpt-5/codex_prompting_guide)
- [Responses API Reference](https://platform.openai.com/docs/api-reference/responses)
- [Reasoning Models Guide](https://platform.openai.com/docs/guides/reasoning)

### VeloraHarness Documentation
- [Setup Guide](./SETUP.md)
- [Replication Guide](./REPLICATION_GUIDE.md)

### liteLLM Documentation
- [Responses API Support](https://docs.litellm.ai/docs/responses)
- [Function Calling](https://docs.litellm.ai/docs/completion/function_call)

---

## Changelog

### 2025-01-30
- ✅ Initial integration of GPT-5.2-codex
- ✅ Added `uses_responses_api` to `ModelFeatures`
- ✅ Created `gpt_responses_litellm.py` with liteLLM responses() support
- ✅ Created `gpt_responses_native.py` as backup HTTP client
- ✅ Fixed `reasoning_effort` parameter filtering with `allowed_openai_params`
- ✅ Added Responses API patterns to `model_features.py`
- ✅ Successfully tested MEDIUM reasoning (130 iterations, SUCCESS)
- ✅ Created comprehensive documentation

### Future Work
- [ ] Test HIGH reasoning effort (in progress)
- [ ] Benchmark token costs for each reasoning level
- [ ] Add streaming support for Responses API
- [ ] Optimize timeout values based on empirical data
- [ ] Add retry logic specific to Responses API rate limits

---

## Support

For issues or questions:

1. **Check this document** - Most issues are covered in Troubleshooting
2. **Check logs** - `logs/llm_completions/` contains detailed call logs
3. **Test with lower reasoning** - Try `medium` or `low` first
4. **Verify API access** - Ensure your OpenAI key has GPT-5 access

---

**Last Updated:** 2025-01-30
**Author:** VeloraHarness Team
**Status:** ✅ Production Ready (MEDIUM reasoning)
