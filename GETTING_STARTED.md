# Getting Started with VeloraTrajectories

## What I've Set Up For You

I've configured a complete multi-model trajectory generation system using your Repomate CSV data and the VeloraHarness framework.

### 📁 Files Created

1. **[config.toml](jaeger/VeloraHarness/config.toml)** - Multi-model configuration
   - Claude Opus 4.6
   - Claude Sonnet 4.5
   - Kimi K2
   - Qwen3 Coder
   - GPT-5.2
   - Gemini 3 Pro (for history condensation)

2. **[convert_csv_to_jsonl.py](convert_csv_to_jsonl.py)** - CSV→JSONL converter
   - Converts 230K+ Repomate tasks to VeloraHarness format
   - Supports filtering by language and limiting output

3. **[generate_trajectories.sh](generate_trajectories.sh)** - Batch trajectory generation
   - Runs all models sequentially
   - Saves outputs to organized directories
   - Logs all progress

4. **[evaluate_trajectories.sh](evaluate_trajectories.sh)** - Batch evaluation
   - Tests generated patches against test suites
   - Produces pass/fail statistics
   - Multi-language support (Go, Python, Java, Rust, C++)

5. **[quick_test.sh](quick_test.sh)** - Quick setup verification
   - Tests your configuration
   - Converts sample data
   - Checks dependencies

6. **[README_SETUP.md](README_SETUP.md)** - Complete setup guide
   - Detailed instructions for every step
   - Troubleshooting tips
   - Cost estimates

## 🚀 Quick Start (3 Steps)

### Step 1: Configure API Keys

```bash
cd ~/VeloraTrajectories/jaeger/VeloraHarness
nano config.toml
```

Replace these placeholders with your actual keys:
- `YOUR_ANTHROPIC_API_KEY_HERE`
- `YOUR_MOONSHOT_API_KEY_HERE`
- `YOUR_QWEN_API_KEY_HERE`
- `YOUR_OPENAI_API_KEY_HERE`
- `YOUR_GOOGLE_API_KEY_HERE`

### Step 2: Test Setup

```bash
cd ~/VeloraTrajectories
./quick_test.sh
```

This will:
- Convert 5 sample tasks to JSONL
- Verify your configuration
- Check dependencies

### Step 3: Generate Trajectories

```bash
# Small test run (5 tasks, ~30 min)
./generate_trajectories.sh jaeger/VeloraHarness/data/test_tasks.jsonl 5 outputs/test/

# Production run (100 tasks, ~8-12 hours)
python convert_csv_to_jsonl.py \
    --csv "repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv" \
    --output jaeger/VeloraHarness/data/tasks_100.jsonl \
    --limit 100

./generate_trajectories.sh jaeger/VeloraHarness/data/tasks_100.jsonl 100 outputs/run1/
```

## 📊 Your Data

### CSV Files

| File | Rows | Purpose |
|------|------|---------|
| `repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv` | 230,833 | Full task dataset |
| `repomate_images_for_rubrics_300_sample.csv` | 300 | Sample Docker images |
| `image_mapping.csv` | - | Internal→ECR URI mapping |

### Task Distribution by Language

The CSV contains tasks for multiple programming languages. You can filter by language:

```bash
# Python tasks only
python convert_csv_to_jsonl.py \
    --csv "repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv" \
    --output data/python_tasks.jsonl \
    --language python \
    --limit 50

# Go tasks only
python convert_csv_to_jsonl.py \
    --csv "repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv" \
    --output data/go_tasks.jsonl \
    --language go \
    --limit 50
```

## 🤖 Models Configured

### 1. Claude Opus 4.6 (`llm.opus`)
- **Best for**: Complex reasoning, large codebases
- **Context**: 200K tokens
- **Cost**: ~$150-200 per 100 tasks

### 2. Kimi K2 (`llm.kimi`)
- **Best for**: Long context understanding
- **Context**: 2M tokens
- **Cost**: ~$50-80 per 100 tasks

### 3. Qwen3 Coder (`llm.qwen`)
- **Best for**: Optimized code generation
- **Context**: 128K tokens
- **Cost**: ~$30-50 per 100 tasks

### 4. GPT-5.2 (`llm.gpt`)
- **Best for**: General-purpose coding
- **Context**: TBD
- **Cost**: ~$100-150 per 100 tasks (estimate)

## 📂 Output Structure

After running trajectories, you'll have:

```
outputs/
├── Claude_Opus_4.6/
│   ├── output.jsonl           # Generated patches
│   ├── eval_output.jsonl      # Test results
│   ├── generation.log         # Generation logs
│   └── evaluation.log         # Evaluation logs
├── Kimi_K2/
├── Qwen3_Coder/
└── GPT_5.2/
```

## 🐳 Docker Image Requirements

The evaluation requires Docker images from your registry. The images are specified in the CSV data.

**Example workflow:**

```bash
# 1. Find image URI from CSV
grep "1841270650076475" "repomate_sample_for_rubric_annotations_with_data on 2025-12-11.csv" | cut -d',' -f20

# 2. Pull image
docker pull vmvm-registry.fbinfra.net/repomate_image_activ_go_test/meroxa_cli:d45265fa27f5700a0a494a0f0597f340c485663c

# 3. Tag for VeloraHarness
docker tag vmvm-registry.fbinfra.net/repomate_image_activ_go_test/meroxa_cli:d45265fa27f5700a0a494a0f0597f340c485663c \
    mswebench/meroxa_m_cli:pr-1841270650076475
```

## 📈 Monitoring Progress

### Check generation progress:
```bash
tail -f outputs/Claude_Opus_4.6/generation.log
```

### Check evaluation results:
```bash
# Show resolved tasks
grep '"resolved":true' outputs/Claude_Opus_4.6/eval_output.jsonl | wc -l

# Show failed tasks
grep '"resolved":false' outputs/Claude_Opus_4.6/eval_output.jsonl | wc -l
```

### Compare models:
```bash
for model in Claude_Opus_4.6 Kimi_K2 Qwen3_Coder GPT_5.2; do
    resolved=$(grep -o '"resolved":true' "outputs/$model/eval_output.jsonl" | wc -l || echo "0")
    total=$(wc -l < "outputs/$model/eval_output.jsonl" || echo "0")
    echo "$model: $resolved/$total resolved"
done
```

## ⚡ Performance Tips

### 1. Start Small
Begin with 5-10 tasks to verify setup and estimate costs:
```bash
./quick_test.sh
./generate_trajectories.sh jaeger/VeloraHarness/data/test_tasks.jsonl 5 outputs/test/
```

### 2. Filter by Language
Focus on one language for faster debugging:
```bash
python convert_csv_to_jsonl.py --language go --limit 20 --output data/go_20.jsonl --csv "..."
```

### 3. Parallel Execution
Run different models in parallel (requires sufficient resources):
```bash
# Terminal 1: Claude
cd jaeger/VeloraHarness && poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --llm-config llm.opus --dataset ../../data/tasks.jsonl --eval-n-limit 10 --eval-output-dir ../../outputs/opus/ &

# Terminal 2: Kimi
cd jaeger/VeloraHarness && poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --llm-config llm.kimi --dataset ../../data/tasks.jsonl --eval-n-limit 10 --eval-output-dir ../../outputs/kimi/ &
```

### 4. Adjust Iterations
Reduce max iterations for faster testing:
```bash
# In config.toml
[core]
max_iterations = 100  # Instead of 500
```

## 🆘 Troubleshooting

### Problem: "API key not configured"
**Solution**: Edit `jaeger/VeloraHarness/config.toml` and add your keys

### Problem: "Docker image not found"
**Solution**: Pull and tag the image correctly (see Docker Image Requirements above)

### Problem: "Poetry not found"
**Solution**: Install poetry:
```bash
curl -sSL https://install.python-poetry.org | python3 -
# Add to PATH: export PATH="$HOME/.local/bin:$PATH"
```

### Problem: "Memory error during CSV conversion"
**Solution**: Process in smaller batches:
```bash
python convert_csv_to_jsonl.py --limit 1000 --csv "..." --output data/batch1.jsonl
python convert_csv_to_jsonl.py --limit 1000 --csv "..." --output data/batch2.jsonl --offset 1000
```

## 📚 Documentation

- **[README_SETUP.md](README_SETUP.md)** - Detailed setup guide
- **[VeloraHarness README](jaeger/VeloraHarness/README.md)** - Framework documentation
- **[VeloraHarness Setup](jaeger/VeloraHarness/docs/SETUP.md)** - Installation guide

## 🎯 Recommended Workflow

### Phase 1: Validation (Day 1)
1. ✅ Configure API keys
2. ✅ Run quick test (5 tasks)
3. ✅ Verify outputs and costs
4. ✅ Adjust configuration if needed

### Phase 2: Pilot (Days 2-3)
1. Convert 50-100 tasks by language
2. Generate trajectories for all models
3. Evaluate and compare results
4. Identify optimal model per language

### Phase 3: Production (Days 4+)
1. Convert full dataset (230K tasks)
2. Run batch processing
3. Analyze results across models
4. Generate comparison reports

## 💡 Key Features

✅ **Multi-model support** - Compare 4 models in one run
✅ **Multi-language** - Go, Python, Java, Rust, C++
✅ **Batch processing** - Handle 230K+ tasks
✅ **Automatic evaluation** - Test generated patches
✅ **Cost tracking** - Monitor API usage
✅ **Error handling** - Retries and logging
✅ **Resumable** - Continue from failures

## 📊 Expected Results

After running 100 tasks across all models, you'll have:
- **400 trajectory files** (100 × 4 models)
- **Evaluation metrics** (pass/fail rates)
- **Cost breakdown** by model
- **Performance comparison** data
- **Token usage statistics**

---

**Ready to start?** Run `./quick_test.sh` to verify your setup!
