# ⚠️  IMPORTANT SETUP NOTES

## Why config.toml and poetry.lock are Included

Unlike typical open-source projects, VeloraHarness includes:
- ✅ `config.toml` (usually gitignored)
- ✅ `poetry.lock` (usually gitignored)  
- ✅ `pyproject.toml` (usually included)

### Reason

Team members experienced Poetry dependency resolution issues when these files were excluded. Including them ensures:
1. **Consistent environment** - Everyone gets same dependency versions
2. **Faster setup** - No dependency resolution needed
3. **Fewer errors** - Avoid Poetry conflicts

### Security Warning

**config.toml contains placeholder API keys, NOT real keys.**

Before running, you MUST:
1. Open `config.toml`
2. Replace ALL placeholders with your actual API keys:
   - `YOUR_OPENAI_API_KEY_HERE`
   - `YOUR_ANTHROPIC_API_KEY_HERE`
   - `YOUR_MOONSHOT_API_KEY_HERE`
   - `YOUR_QWEN_API_KEY_HERE`

### If You Fork This Repository

**Do NOT commit your real API keys!**

Before pushing your fork:
```bash
# Replace your actual keys with placeholders
sed -i 's/sk-proj-[A-Za-z0-9_-]*/YOUR_OPENAI_API_KEY_HERE/g' config.toml
sed -i 's/sk-ant-[A-Za-z0-9_-]*/YOUR_ANTHROPIC_API_KEY_HERE/g' config.toml
```

## Quick Setup

```bash
# 1. Clone
git clone <repo>
cd VeloraHarness

# 2. Install dependencies (uses included poetry.lock)
poetry install --no-root

# 3. Add your API keys to config.toml
nano config.toml

# 4. Ready to use!
poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py --help
```

That's it! No dependency resolution issues.
