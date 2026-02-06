# Test VeloraTrajectories with Gemini Only

This guide shows how to test the entire pipeline using just the Gemini API key before getting keys from other providers.

## ✅ What's Already Configured

Your Gemini API key is already set in the config:
```
API Key: REDACTED_GOOGLE_API_KEY
Model: gemini/gemini-2.0-flash-exp
```

## 🧪 Quick Test (Recommended)

### Option 1: Automated Test Script (Easiest)

```bash
cd ~/VeloraTrajectories
./test_gemini_only.sh
```

This will:
- Convert 2 sample tasks from CSV
- Generate trajectories using Gemini
- Save results to `outputs/gemini_test/`
- Take ~5-10 minutes

### Option 2: Manual Test (More Control)

```bash
cd ~/VeloraTrajectories

# 1. Convert a few tasks
python convert_csv_to_jsonl.py \
    --csv "repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv" \
    --output jaeger/VeloraHarness/data/test.jsonl \
    --limit 3

# 2. Generate trajectories with Gemini
cd jaeger/VeloraHarness
export PYTHONPATH="$(pwd):$PYTHONPATH"
export DOCKER_BUILDKIT=0
export USE_INSTANCE_IMAGE=true

poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent-cls CodeActAgent \
    --llm-config llm.gemini \
    --max-iterations 50 \
    --eval-num-workers 1 \
    --dataset data/test.jsonl \
    --split train \
    --eval-n-limit 3 \
    --eval-output-dir ../../outputs/test/
```

## 📊 What to Expect

### Success Indicators

✅ **No errors during CSV conversion**
```
✓ Converted 3 instances to jaeger/VeloraHarness/data/test.jsonl
```

✅ **Agent starts successfully**
```
INFO: Creating runtime...
INFO: Runtime created successfully
INFO: Starting agent loop...
```

✅ **Gemini API calls work**
```
INFO: LLM response received
INFO: Action: CmdRunAction
```

✅ **Trajectory saved**
```
✓ Output file: outputs/test/output.jsonl
```

### Common Issues

❌ **"API key invalid"**
- The key might be expired or have insufficient permissions
- Verify at: https://makersuite.google.com/app/apikey

❌ **"Docker image not found"**
- This is expected for now - you need to download/load the Docker images
- See "Docker Setup" section below

❌ **"Poetry not found"**
```bash
curl -sSL https://install.python-poetry.org | python3 -
export PATH="$HOME/.local/bin:$PATH"
cd ~/VeloraTrajectories/jaeger/VeloraHarness
poetry install
```

## 🐳 Docker Image Setup (Required for Evaluation)

The test will generate trajectories, but evaluation requires Docker images. Here's how to set them up:

### 1. Find the Image URI

```bash
# Extract image URI from your test task
head -1 jaeger/VeloraHarness/data/test.jsonl | python -c "import sys, json; print(json.load(sys.stdin)['image_storage_uri'])"
```

### 2. Pull and Tag Image

```bash
# Example for the first task in your CSV
docker pull vmvm-registry.fbinfra.net/repomate_image_activ_go_test/meroxa_cli:d45265fa27f5700a0a494a0f0597f340c485663c

# Tag for VeloraHarness
docker tag vmvm-registry.fbinfra.net/repomate_image_activ_go_test/meroxa_cli:d45265fa27f5700a0a494a0f0597f340c485663c \
    mswebench/meroxa_m_cli:pr-1841270650076475
```

### 3. Verify Image

```bash
docker images | grep mswebench
```

## 📈 Understanding the Output

### Output File: `outputs/test/output.jsonl`

Each line contains a trajectory:

```json
{
  "instance_id": "1841270650076475",
  "test_result": {
    "git_patch": "diff --git a/file.go ...",
    "exit_code": 0
  },
  "history": [
    {"action": "read_file", "result": "..."},
    {"action": "edit_file", "result": "..."}
  ],
  "metrics": {
    "cost": 0.05,
    "iterations": 15,
    "success": true
  }
}
```

### Key Metrics

- **cost**: API cost in USD
- **iterations**: Number of agent steps
- **git_patch**: Generated code changes
- **exit_code**: 0 = success, non-zero = failure

## 💰 Cost Estimate

**Gemini 2.0 Flash Pricing:**
- Input: $0.075 per 1M tokens
- Output: $0.30 per 1M tokens

**For 3 tasks @ 50 iterations:**
- Estimated cost: $0.10 - $0.50
- Very cheap for testing!

## ✅ What This Test Proves

If the test succeeds, you've validated:

1. ✅ CSV to JSONL conversion works
2. ✅ VeloraHarness is configured correctly
3. ✅ Gemini API integration works
4. ✅ CodeActAgent can generate trajectories
5. ✅ The entire pipeline is functional

## 🎯 Next Steps After Successful Test

### 1. Get API Keys for Other Models

Now that the pipeline works, get keys from:
- **Anthropic** (Claude Opus 4.6): https://console.anthropic.com/
- **Moonshot** (Kimi 2.5): https://platform.moonshot.cn/
- **OpenRouter** (Qwen3 Coder): https://openrouter.ai/
- **OpenAI** (GPT-4o): https://platform.openai.com/

### 2. Update config.toml

```bash
cd ~/VeloraTrajectories
nano jaeger/VeloraHarness/config.toml
```

Add your keys for each `[llm.*]` section.

### 3. Run Full Batch

```bash
# Convert more tasks (e.g., 50)
python convert_csv_to_jsonl.py \
    --csv "repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv" \
    --output jaeger/VeloraHarness/data/tasks_50.jsonl \
    --limit 50

# Run all 4 models
./generate_trajectories.sh jaeger/VeloraHarness/data/tasks_50.jsonl 50 outputs/production/
```

### 4. Evaluate Results

```bash
./evaluate_trajectories.sh outputs/production/ jaeger/VeloraHarness/data/tasks_50.jsonl mswebench
```

### 5. Analyze Performance

```bash
python analyze_results.py --output-dir outputs/production/
```

## 🔍 Viewing Results

### View trajectory details:
```bash
cat outputs/gemini_test/output.jsonl | python -m json.tool | less
```

### Check specific instance:
```bash
jq 'select(.instance_id=="1841270650076475")' outputs/gemini_test/output.jsonl | python -m json.tool
```

### View logs:
```bash
tail -f outputs/gemini_test/test.log
```

### Count successful tasks:
```bash
grep '"success":true' outputs/gemini_test/output.jsonl | wc -l
```

## 🆘 Troubleshooting

### Test fails immediately
```bash
# Check Python environment
cd jaeger/VeloraHarness
poetry install
poetry shell
```

### CSV conversion fails
```bash
# Try with a specific instance ID
python convert_csv_to_jsonl.py \
    --csv "repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv" \
    --output test.jsonl \
    --instance-id "1841270650076475"
```

### Gemini API errors
```bash
# Test API key directly
curl -X POST \
  "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:generateContent?key=REDACTED_GOOGLE_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"contents":[{"parts":[{"text":"Hello"}]}]}'
```

## 📞 Support

If the test succeeds:
- ✅ You're ready to get other API keys
- ✅ The pipeline is working correctly
- ✅ You can scale up to more tasks

If the test fails:
- Check the log: `outputs/gemini_test/test.log`
- Verify Gemini API key is active
- Ensure Poetry is installed and dependencies are ready
- Review error messages for specific issues

---

**Ready to test?** Run: `./test_gemini_only.sh`
