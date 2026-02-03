# Pre-Commit Checklist for VeloraHarness

## ✅ Before Pushing to GitHub

### 1. Verify Critical Files Are Staged

```bash
# Check what will be committed
git status

# MUST include:
# ✅ openhands/runtime/utils/runtime_templates/Dockerfile.j2 (with tmux fix!)
# ✅ evaluation/benchmarks/client_tasks/ (all scripts)
# ✅ config.toml.example (template for teammates)
# ✅ SETUP.md (installation guide)
# ✅ Any new .py scripts
```

### 2. Verify Secrets Are NOT Staged

```bash
# Check for accidentally staged secrets
git diff --cached | grep -E "api_key|sk-|AWS_SECRET|password"

# If any matches found:
git reset HEAD path/to/file/with/secret
# Then remove the secret from the file and re-stage
```

**Common files to NEVER commit:**
- ❌ `config.toml` (contains API keys)
- ❌ `*.env` files
- ❌ `*.pem` SSH keys
- ❌ `*.log` files with sensitive data

### 3. Verify the Dockerfile.j2 Fix Is Present

```bash
# Check the critical fix
grep -A 3 "tmux build-essential" openhands/runtime/utils/runtime_templates/Dockerfile.j2

# Should output:
#         tmux build-essential || true && \
#     apt-get clean && rm -rf /var/lib/apt/lists/*
```

### 4. Check for Large Files

```bash
# Find files larger than 50MB (GitHub has a 100MB limit)
find . -type f -size +50M | grep -v ".git"

# If any found, add to .gitignore:
echo "path/to/large/file" >> .gitignore
```

### 5. Verify .gitignore is Correct

```bash
# Test .gitignore rules
git check-ignore -v outputs/test.txt  # Should be ignored
git check-ignore -v config.toml  # Should be ignored
git check-ignore -v config.toml.example  # Should NOT be ignored
git check-ignore -v openhands/runtime/utils/runtime_templates/Dockerfile.j2  # Should NOT be ignored
```

### 6. Run Local Tests (if applicable)

```bash
# Test import
poetry run python -c "import openhands; print('OK')"

# Test config.toml.example is valid
cp config.toml.example /tmp/test_config.toml
# Manually verify it has all required sections
```

### 7. Review Commit Message

```bash
# Good commit message format:
git commit -m "fix: Add tmux to Dockerfile.j2 for mswebench images

- Resolves TmuxCommandNotFound errors in runtime containers
- Required for OpenHands agent bash session management
- Tested on AWS instance with 67KB patch generation success"
```

### 8. Final Git Commands

```bash
# Stage the Dockerfile.j2 fix
git add openhands/runtime/utils/runtime_templates/Dockerfile.j2

# Stage client_tasks directory (if new)
git add evaluation/benchmarks/client_tasks/

# Stage documentation
git add SETUP.md PRE_COMMIT_CHECKLIST.md

# Review what will be committed
git diff --cached --stat

# Commit with descriptive message
git commit -m "fix: Add tmux to mswebench runtime images"

# Push to GitHub
git push origin main
```

## 🔍 Files That SHOULD Be Committed

### Source Code
- ✅ `openhands/**/*.py` (all Python source files)
- ✅ `evaluation/**/*.py` (all evaluation scripts)
- ✅ `openhands/runtime/utils/runtime_templates/Dockerfile.j2` ⭐ **CRITICAL FIX**

### Configuration Templates
- ✅ `config.toml.example` (NOT `config.toml`)
- ✅ `.gitignore`
- ✅ `pyproject.toml` (if present)

### Documentation
- ✅ `README.md`
- ✅ `SETUP.md`
- ✅ `PRE_COMMIT_CHECKLIST.md`
- ✅ `evaluation/benchmarks/client_tasks/README.md`

### Scripts
- ✅ `evaluation/benchmarks/client_tasks/scripts/*.sh`
- ✅ Any `*.sh` or `*.py` helper scripts

## ❌ Files That Should NEVER Be Committed

### Secrets & Credentials
- ❌ `config.toml` (contains real API keys)
- ❌ `.env`, `.env.local`, etc.
- ❌ `*.pem` (SSH keys)
- ❌ AWS credentials files

### Generated/Runtime Files
- ❌ `poetry.lock` (per project .gitignore)
- ❌ `*.log` files
- ❌ `outputs/`
- ❌ `evaluation_outputs/`
- ❌ `llm_completions/`
- ❌ `*.tar` (Docker images)
- ❌ `__pycache__/`, `*.pyc`

### IDE/Editor Files
- ❌ `.vscode/` (except specific settings if needed)
- ❌ `.idea/`
- ❌ `.cursorrules` (project-specific, usually not shared)
- ❌ `.DS_Store` (macOS)

## 🚨 Emergency: Accidentally Committed a Secret

```bash
# If you committed but haven't pushed:
git reset --soft HEAD~1  # Undo commit, keep changes
# Remove the secret from the file
git add .
git commit -m "Your commit message"

# If you already pushed:
# 1. Rotate the exposed API key IMMEDIATELY
# 2. Use git filter-branch or BFG Repo-Cleaner to remove from history
# 3. Force push (coordinate with team first!)

# Better: Use git-secrets to prevent this
# https://github.com/awslabs/git-secrets
```

## 📋 Quick Reference

```bash
# Before every push:
1. git status  # Review what's staged
2. git diff --cached  # Review changes
3. grep -r "sk-" .  # Check for API keys (excluding config.toml)
4. git push origin main

# After teammate clones:
1. cp config.toml.example config.toml
2. # Fill in API keys in config.toml
3. poetry install
4. poetry shell
```

---

**Remember**: The `.gitignore` is your friend! It's already configured to block sensitive files. Review this checklist before every commit to keep the repository secure and clean.

