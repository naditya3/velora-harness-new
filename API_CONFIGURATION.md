# API Configuration Guide

This guide shows you how to configure API keys for each model.

## API Sources

### 1. Claude Opus 4.6 (Anthropic/Claude API)

**Provider**: Anthropic
**API Endpoint**: `https://api.anthropic.com`
**Model**: `claude-opus-4-6`

**How to get API key**:
1. Go to: https://console.anthropic.com/
2. Sign up or log in
3. Navigate to "API Keys"
4. Create a new key
5. Copy the key starting with `sk-ant-...`

**Add to config.toml**:
```toml
[llm.opus]
model = "claude-opus-4-6"
api_key = "sk-ant-api03-..."
base_url = "https://api.anthropic.com"
```

---

### 2. Kimi 2.5 (Moonshot API)

**Provider**: Moonshot AI
**API Endpoint**: `https://api.moonshot.cn/v1`
**Model**: `moonshot-v1-128k`

**How to get API key**:
1. Go to: https://platform.moonshot.cn/
2. Sign up or log in
3. Navigate to API Keys section
4. Create a new key
5. Copy the key

**Add to config.toml**:
```toml
[llm.kimi]
model = "moonshot-v1-128k"
api_key = "sk-..."
base_url = "https://api.moonshot.cn/v1"
```

**Available Kimi models**:
- `moonshot-v1-8k` - 8K context
- `moonshot-v1-32k` - 32K context
- `moonshot-v1-128k` - 128K context (recommended)

---

### 3. Qwen3 Coder (OpenRouter API)

**Provider**: OpenRouter
**API Endpoint**: `https://openrouter.ai/api/v1`
**Model**: `qwen/qwen-2.5-coder-32b-instruct`

**How to get API key**:
1. Go to: https://openrouter.ai/
2. Sign up or log in
3. Navigate to "Keys" section
4. Create a new key
5. Copy the key starting with `sk-or-v1-...`

**Add to config.toml**:
```toml
[llm.qwen]
model = "qwen/qwen-2.5-coder-32b-instruct"
api_key = "sk-or-v1-..."
base_url = "https://openrouter.ai/api/v1"
```

**Available Qwen models on OpenRouter**:
- `qwen/qwen-2.5-coder-32b-instruct` - Best for coding
- `qwen/qwen-2.5-72b-instruct` - General purpose
- `qwen/qwen-2-72b-instruct` - Previous generation

---

### 4. GPT-5.2 (OpenAI API)

**Provider**: OpenAI
**API Endpoint**: `https://api.openai.com/v1`
**Model**: `gpt-4o` (update to `gpt-5.2` when available)

**How to get API key**:
1. Go to: https://platform.openai.com/
2. Sign up or log in
3. Navigate to "API Keys"
4. Create a new key
5. Copy the key starting with `sk-...`

**Add to config.toml**:
```toml
[llm.gpt]
model = "gpt-4o"
api_key = "sk-..."
base_url = "https://api.openai.com/v1"
```

**Note**: GPT-5.2 may not be released yet. Use `gpt-4o` or `gpt-4-turbo` as alternatives.

**Available OpenAI models**:
- `gpt-4o` - Latest GPT-4 optimized
- `gpt-4-turbo` - Fast GPT-4
- `gpt-4` - Standard GPT-4

---

### 5. Gemini 3 Pro (Google API) - For History Condensation

**Provider**: Google
**API Endpoint**: Uses LiteLLM with `gemini/` prefix
**Model**: `gemini/gemini-3-pro-preview`

**How to get API key**:
1. Go to: https://makersuite.google.com/app/apikey
2. Sign up or log in with Google account
3. Create an API key
4. Copy the key

**Add to config.toml**:
```toml
[llm.gemini]
model = "gemini/gemini-3-pro-preview"
api_key = "AIza..."
```

**Note**: The `gemini/` prefix tells VeloraHarness to use LiteLLM's Gemini integration.

---

## Complete Configuration Example

Edit `jaeger/VeloraHarness/config.toml`:

```toml
###################### VeloraHarness Configuration ######################

[core]
max_iterations = 500
default_agent = "CodeActAgent"

#################################### LLM #####################################

# Claude Opus 4.6 (Anthropic)
[llm.opus]
model = "claude-opus-4-6"
api_key = "sk-ant-api03-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
base_url = "https://api.anthropic.com"
temperature = 1.0
timeout = 600
num_retries = 8
retry_min_wait = 15
retry_max_wait = 120

# Kimi 2.5 (Moonshot)
[llm.kimi]
model = "moonshot-v1-128k"
api_key = "sk-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
base_url = "https://api.moonshot.cn/v1"
temperature = 1.0
timeout = 600
num_retries = 12
retry_min_wait = 30
retry_max_wait = 180

# Qwen3 Coder (OpenRouter)
[llm.qwen]
model = "qwen/qwen-2.5-coder-32b-instruct"
api_key = "sk-or-v1-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
base_url = "https://openrouter.ai/api/v1"
temperature = 1.0
timeout = 600
num_retries = 8
retry_min_wait = 15
retry_max_wait = 120

# GPT-4o (OpenAI) - Will update to GPT-5.2 when available
[llm.gpt]
model = "gpt-4o"
api_key = "sk-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
base_url = "https://api.openai.com/v1"
temperature = 1.0
timeout = 600
num_retries = 8
retry_min_wait = 15
retry_max_wait = 120

# Gemini (Google) - For history condensation
[llm.gemini]
model = "gemini/gemini-3-pro-preview"
api_key = "AIzaXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
temperature = 1.0
timeout = 600
num_retries = 12
retry_min_wait = 30
retry_max_wait = 180

#################################### Agent ###################################
[agent]
enable_cmd = true
enable_finish = true
enable_editor = true

#################################### Sandbox ###################################
[sandbox]
runtime_container_image = "ghcr.io/openhands/runtime:velora_ready"
timeout = 300

#################################### Condenser #################################
[condenser]
type = "llm"
llm_config = "gemini"
max_size = 250
keep_first = 2
```

---

## Testing Your Configuration

### Test API Keys

```bash
cd ~/VeloraTrajectories

# Test Claude
curl https://api.anthropic.com/v1/messages \
  -H "x-api-key: YOUR_ANTHROPIC_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-opus-4-6","max_tokens":10,"messages":[{"role":"user","content":"Hi"}]}'

# Test OpenAI
curl https://api.openai.com/v1/chat/completions \
  -H "Authorization: Bearer YOUR_OPENAI_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Hi"}],"max_tokens":10}'

# Test Moonshot
curl https://api.moonshot.cn/v1/chat/completions \
  -H "Authorization: Bearer YOUR_MOONSHOT_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"moonshot-v1-8k","messages":[{"role":"user","content":"Hi"}],"max_tokens":10}'

# Test OpenRouter
curl https://openrouter.ai/api/v1/chat/completions \
  -H "Authorization: Bearer YOUR_OPENROUTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen/qwen-2.5-coder-32b-instruct","messages":[{"role":"user","content":"Hi"}],"max_tokens":10}'
```

### Run Quick Test

```bash
cd ~/VeloraTrajectories
./quick_test.sh
```

This will check if your configuration is valid.

---

## Cost Estimates (per 100 tasks @ 500 iterations)

| Model | Provider | Cost/1M Input | Cost/1M Output | Est. Total |
|-------|----------|---------------|----------------|------------|
| **Claude Opus 4.6** | Anthropic | $15 | $75 | ~$150-200 |
| **Kimi 2.5 (128k)** | Moonshot | ¥12 (~$1.65) | ¥12 (~$1.65) | ~$50-80 |
| **Qwen3 Coder (32B)** | OpenRouter | $0.70 | $0.70 | ~$30-50 |
| **GPT-4o** | OpenAI | $2.50 | $10 | ~$80-120 |

**Note**: Actual costs depend on:
- Task complexity
- Number of iterations needed
- Context length
- Retry attempts

**Recommendation**: Start with 5-10 tasks to measure actual costs before scaling up.

---

## Environment Variables (Alternative)

Instead of editing `config.toml`, you can set environment variables:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
export MOONSHOT_API_KEY="sk-..."
export OPENROUTER_API_KEY="sk-or-v1-..."
export OPENAI_API_KEY="sk-..."
export GOOGLE_API_KEY="AIza..."
```

Then VeloraHarness will read from environment variables if keys are not in config.toml.

---

## Troubleshooting

### Problem: "Invalid API key"
**Solution**: Verify key is correct and has proper permissions

### Problem: "Rate limit exceeded"
**Solution**: Increase retry delays in config.toml or reduce parallel requests

### Problem: "Model not found"
**Solution**: Check model name matches provider's documentation

### Problem: "Connection timeout"
**Solution**: Increase timeout value or check network connectivity

---

## Security Best Practices

1. ✅ Never commit API keys to git
2. ✅ Use environment variables for production
3. ✅ Rotate keys regularly
4. ✅ Set spending limits on each provider
5. ✅ Monitor API usage in provider dashboards
6. ✅ Keep `config.toml` out of version control (add to `.gitignore`)

---

## Next Steps

1. ✅ Get API keys from all providers
2. ✅ Add keys to `config.toml`
3. ✅ Test with `./quick_test.sh`
4. ✅ Run small batch: `./generate_trajectories.sh data/test_tasks.jsonl 5 outputs/test/`
5. ✅ Scale up based on results
