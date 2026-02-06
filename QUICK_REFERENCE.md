# VeloraTrajectories - Quick Reference Card

## 🔑 API Keys Needed

| Model | Provider | API Endpoint | Get Key From |
|-------|----------|--------------|--------------|
| **Claude Opus 4.6** | Anthropic | `https://api.anthropic.com` | https://console.anthropic.com/ |
| **Kimi 2.5** | Moonshot | `https://api.moonshot.cn/v1` | https://platform.moonshot.cn/ |
| **Qwen3 Coder** | OpenRouter | `https://openrouter.ai/api/v1` | https://openrouter.ai/ |
| **GPT-4o** | OpenAI | `https://api.openai.com/v1` | https://platform.openai.com/ |
| **Gemini** | Google | (via LiteLLM) | https://makersuite.google.com/app/apikey |

## 📝 Configuration File

Edit: `jaeger/VeloraHarness/config.toml`

```toml
[llm.opus]
model = "claude-opus-4-6"
api_key = "sk-ant-api03-..."          # Your Anthropic key
base_url = "https://api.anthropic.com"

[llm.kimi]
model = "moonshot-v1-128k"
api_key = "sk-..."                     # Your Moonshot key
base_url = "https://api.moonshot.cn/v1"

[llm.qwen]
model = "qwen/qwen-2.5-coder-32b-instruct"
api_key = "sk-or-v1-..."               # Your OpenRouter key
base_url = "https://openrouter.ai/api/v1"

[llm.gpt]
model = "gpt-4o"
api_key = "sk-..."                     # Your OpenAI key
base_url = "https://api.openai.com/v1"

[llm.gemini]
model = "gemini/gemini-3-pro-preview"
api_key = "AIza..."                    # Your Google key
```

## 🚀 Quick Start Commands

### 1. Setup
```bash
cd ~/VeloraTrajectories
nano jaeger/VeloraHarness/config.toml  # Add API keys
./quick_test.sh                         # Verify setup
```

### 2. Convert CSV to JSONL
```bash
# Test with 10 tasks
python convert_csv_to_jsonl.py \
    --csv "repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv" \
    --output jaeger/VeloraHarness/data/tasks.jsonl \
    --limit 10

# Filter by language
python convert_csv_to_jsonl.py \
    --csv "repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv" \
    --output jaeger/VeloraHarness/data/go_tasks.jsonl \
    --language go \
    --limit 50
```

### 3. Generate Trajectories
```bash
# All 4 models, 10 tasks
./generate_trajectories.sh jaeger/VeloraHarness/data/tasks.jsonl 10 outputs/

# Single model only
cd jaeger/VeloraHarness
export PYTHONPATH="$(pwd):$PYTHONPATH"
poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent-cls CodeActAgent \
    --llm-config llm.opus \
    --max-iterations 500 \
    --dataset data/tasks.jsonl \
    --eval-n-limit 10 \
    --eval-output-dir ../../outputs/Claude_Opus_4.6/
```

### 4. Evaluate
```bash
./evaluate_trajectories.sh outputs jaeger/VeloraHarness/data/tasks.jsonl mswebench
```

### 5. Analyze
```bash
python analyze_results.py --output-dir outputs/
```

## 📊 Model Comparison

| Model | Context | Speed | Cost/100 Tasks | Best For |
|-------|---------|-------|----------------|----------|
| **Claude Opus 4.6** | 200K | Medium | $150-200 | Complex reasoning |
| **Kimi 2.5** | 128K | Fast | $50-80 | Long context |
| **Qwen3 Coder** | 32K | Very Fast | $30-50 | Code generation |
| **GPT-4o** | 128K | Fast | $80-120 | General purpose |

## 📁 File Structure

```
VeloraTrajectories/
├── config.toml (in jaeger/VeloraHarness/)  ← Add keys here
├── convert_csv_to_jsonl.py                 ← CSV converter
├── generate_trajectories.sh                ← Run all models
├── evaluate_trajectories.sh                ← Test patches
├── analyze_results.py                      ← Compare results
└── outputs/                                ← Results
    ├── Claude_Opus_4.6/
    ├── Kimi_2.5/
    ├── Qwen3_Coder/
    └── GPT_4o/
```

## ⚡ Common Tasks

### Monitor Progress
```bash
# Watch generation logs
tail -f outputs/Claude_Opus_4.6/generation.log

# Count completed tasks
ls outputs/Claude_Opus_4.6/*.jsonl | wc -l

# Check resolved count
grep '"resolved":true' outputs/Claude_Opus_4.6/eval_output.jsonl | wc -l
```

### Filter by Language
```bash
# Python only
python convert_csv_to_jsonl.py --language python --limit 50 --csv "..." --output data/python.jsonl

# Go only
python convert_csv_to_jsonl.py --language go --limit 50 --csv "..." --output data/go.jsonl

# Available: python, go, java, rust, cpp, javascript
```

### Resume Failed Run
```bash
# If generation fails, trajectories are saved incrementally
# Just re-run with same output directory
./generate_trajectories.sh data/tasks.jsonl 100 outputs/
```

## 🐛 Troubleshooting

| Problem | Solution |
|---------|----------|
| API key invalid | Check key format and provider |
| Docker image not found | Pull and tag: `docker pull <uri> && docker tag <uri> mswebench/<name>` |
| Out of memory | Reduce `--eval-n-limit` or split into batches |
| Rate limit hit | Increase retry delays in config.toml |
| Poetry not found | `curl -sSL https://install.python-poetry.org \| python3 -` |

## 💰 Cost Control

### Before Running
```bash
# Start with 5 tasks to estimate costs
./quick_test.sh
./generate_trajectories.sh jaeger/VeloraHarness/data/test_tasks.jsonl 5 outputs/test/
```

### Monitor Spending
- Check provider dashboards regularly
- Set spending limits per provider
- Use `analyze_results.py` to track costs

### Optimize Costs
```toml
# In config.toml - reduce iterations
[core]
max_iterations = 100  # Instead of 500
```

## 📚 Documentation

- **[API_CONFIGURATION.md](API_CONFIGURATION.md)** - Detailed API setup
- **[GETTING_STARTED.md](GETTING_STARTED.md)** - Complete guide
- **[README_SETUP.md](README_SETUP.md)** - Detailed instructions

## ✅ Checklist

- [ ] Get API keys from all 5 providers
- [ ] Edit `jaeger/VeloraHarness/config.toml`
- [ ] Run `./quick_test.sh`
- [ ] Convert CSV: `python convert_csv_to_jsonl.py ...`
- [ ] Test with 5 tasks: `./generate_trajectories.sh ... 5 ...`
- [ ] Review costs and adjust
- [ ] Scale up: `./generate_trajectories.sh ... 100 ...`
- [ ] Evaluate: `./evaluate_trajectories.sh ...`
- [ ] Analyze: `python analyze_results.py ...`

---

**Ready?** Start with: `./quick_test.sh`
