# How Claude Code Rules Work

**Purpose:** Explain how `.claude/rules/*.md` files are used
**Based on:** Claude Code official documentation

---

## **How Claude Code Discovers Rules**

When you (or any Claude Code user) opens the VeloraHarness project:

### **1. Automatic Discovery**

```
You open: /Users/.../VeloraHarness/
Claude Code looks for: .claude/rules/*.md
Finds: 00-critical-fixes.md, 01-trajectory-generation.md, etc.
```

**Claude automatically reads and includes these in its context!**

---

### **2. Ordering and Priority**

Files are read in **alphabetical order**:

```
00-critical-fixes.md        ← Read FIRST (most important)
01-trajectory-generation.md ← Then this
02-deployment.md            ← Then this
03-evaluation.md
04-complete-process.md
README.md                   ← Overview (optional)
```

**That's why we used numbered prefixes!**

---

### **3. Context Inclusion**

Claude Code includes rules in the **system prompt** before processing your request.

**Example conversation:**

```
User: "How do I run trajectory generation?"

Claude's context includes:
  - .claude/rules/00-critical-fixes.md (critical code to maintain)
  - .claude/rules/01-trajectory-generation.md (how to run)
  - .claude/rules/02-deployment.md (deployment info)
  - ... (all rule files)

Claude: "Use the script at evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh
         Here are the parameters: ..."
```

**Claude knows the answer WITHOUT you providing context!**

---

## **Benefits Over .cursorrules**

### **Old Approach: Single .cursorrules File**

```
.cursorrules (one big file)
├── Critical fixes (lines 1-100)
├── Trajectory generation (lines 101-200)
├── Deployment (lines 201-300)
├── Evaluation (lines 301-400)
└── ... everything mixed together
```

**Problems:**
- ❌ Hard to find specific topics
- ❌ Becomes huge and unwieldy
- ❌ Difficult to maintain
- ❌ Not topic-focused

---

### **New Approach: .claude/rules/*.md**

```
.claude/rules/
├── 00-critical-fixes.md          ← Just critical code
├── 01-trajectory-generation.md   ← Just trajectory info
├── 02-deployment.md              ← Just deployment
├── 03-evaluation.md              ← Just evaluation
└── 04-complete-process.md        ← Just workflow
```

**Advantages:**
- ✅ Easy to find and update specific topics
- ✅ Modular and focused
- ✅ Can be edited independently
- ✅ Version controlled
- ✅ Team can contribute specific files
- ✅ Claude Code auto-discovers ALL of them

---

## **How You Use These Rules**

### **Scenario 1: You Want to Run Trajectory Generation**

**What you do:**
```
Open VeloraHarness project in Claude Code
Ask: "How do I run trajectory generation for task X?"
```

**What Claude does:**
1. Reads `.claude/rules/01-trajectory-generation.md`
2. Knows to use `run_full_eval_with_s3.sh`
3. Knows correct parameters
4. Knows troubleshooting steps
5. Gives you exact command

**You get accurate answer immediately!**

---

### **Scenario 2: You Want to Deploy to New Instance**

**What you do:**
```
Ask: "Deploy VeloraHarness to aws-instance-eval2"
```

**What Claude does:**
1. Reads `.claude/rules/02-deployment.md`
2. Knows 4 files to copy
3. Knows checksums to verify
4. Knows verification commands
5. Generates deployment script for you

**You get step-by-step deployment commands!**

---

### **Scenario 3: You Encounter an Error**

**What you do:**
```
Ask: "I'm getting 'ModuleNotFoundError: openhands.agenthub'"
```

**What Claude does:**
1. Reads `.claude/rules/01-trajectory-generation.md` (Troubleshooting section)
2. Finds matching error
3. Provides solution: "Poetry environment issue, run: poetry install"

**You get instant troubleshooting help!**

---

### **Scenario 4: New Team Member Joins**

**What they do:**
```
1. Clone repo
2. Open in Claude Code
3. Ask: "What's the process for running evaluations?"
```

**What Claude does:**
1. Reads `.claude/rules/04-complete-process.md`
2. Provides complete workflow
3. Lists prerequisites
4. Shows examples
5. Points to verification commands

**They're onboarded instantly without reading docs manually!**

---

## **How to Update Rules**

### **When Code Changes:**

```bash
# 1. Edit the appropriate rule file
vim .claude/rules/00-critical-fixes.md

# 2. Update checksums if code changed
md5 -r openhands/runtime/builder/docker.py
# Copy new checksum into 00-critical-fixes.md

# 3. Test on one instance
./scripts/verify_consistency.sh eval1

# 4. Commit to git
git add .claude/rules/
git commit -m "Update critical fixes checksums"

# 5. Team gets updates via git pull
```

---

### **When Process Changes:**

```bash
# Edit the workflow rule
vim .claude/rules/04-complete-process.md

# Add new step or update existing
# Commit to git
git add .claude/rules/04-complete-process.md
git commit -m "Update deployment process"
```

---

## **Rules in Action (Examples)**

### **Example 1: Preventing Common Mistakes**

**User asks:** "I'll run the script from swe_bench folder"

**Claude responds:**
> "⚠️ According to `.claude/rules/01-trajectory-generation.md`, you MUST use
> `multi_swe_bench` not `swe_bench`. The correct path is:
> `evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh`"

**Rules prevent the mistake automatically!**

---

### **Example 2: Ensuring Consistency**

**User asks:** "Deploy to eval2"

**Claude responds:**
> "According to `.claude/rules/02-deployment.md`, you need to copy 4 files
> and verify checksums. Here are the commands:
> [provides exact deployment commands]
> [provides verification commands]"

**Rules ensure consistent deployments!**

---

### **Example 3: Troubleshooting**

**User asks:** "Evaluation failed with error_eval: true"

**Claude responds:**
> "According to `.claude/rules/03-evaluation.md`, error_eval means:
> - Docker container failed to start
> - Dataset file not found
> - Docker image not loaded
>
> Check these commands: [provides diagnostic commands]"

**Rules provide instant troubleshooting!**

---

## **Team Collaboration**

### **Sharing Knowledge:**

**Before (no rules):**
- Knowledge in people's heads
- Inconsistent processes
- Training takes days
- Easy to make mistakes

**After (with rules):**
- Knowledge in `.claude/rules/`
- Consistent processes (Claude enforces)
- Training takes minutes (ask Claude)
- Mistakes prevented proactively

---

### **Contributing:**

**Anyone can update rules:**
```bash
# Developer A adds new troubleshooting tip
vim .claude/rules/01-trajectory-generation.md
git commit -m "Add fix for issue X"
git push

# Developer B pulls changes
git pull

# Claude Code automatically uses updated rules
# Developer B gets new knowledge immediately
```

---

## **Comparison with Traditional Documentation**

### **Traditional Docs (README.md):**
- ❌ You must remember to read it
- ❌ You must search for relevant sections
- ❌ Becomes outdated quickly
- ❌ Claude might not reference it

### **Claude Code Rules:**
- ✅ Claude reads automatically
- ✅ Claude references proactively
- ✅ Always in context
- ✅ Modular and focused
- ✅ Version controlled

---

## **Best Practices**

### **1. Keep Rules Focused**
- One topic per file
- Use clear section headers
- Include practical examples
- Add commands, not just explanations

### **2. Use Numbered Prefixes**
- `00-` for critical/must-read-first content
- `01-` for primary workflows
- `02-` for secondary processes
- Higher numbers for reference material

### **3. Include Verification**
- Add checksum for critical files
- Provide verification commands
- Include "DO" and "DON'T" sections

### **4. Keep Updated**
- Update when code changes
- Update when process improves
- Commit changes to git
- Review quarterly

---

## **Verification**

### **Check if Rules Work:**

```bash
# 1. Open VeloraHarness in Claude Code
cd /Users/.../VeloraHarness
code .  # Or your IDE with Claude Code

# 2. Ask Claude a question
# "What's the correct script for trajectory generation?"

# 3. Claude should reference .claude/rules/01-trajectory-generation.md
# and give you the exact answer

# 4. If it doesn't, check:
ls -la .claude/rules/  # Files exist?
cat .claude/rules/README.md  # Readable?
```

---

## **Our Specific Setup**

### **Files Created (6 rules):**

| File | Purpose | Size | Lines |
|------|---------|------|-------|
| `00-critical-fixes.md` | Code checksums & fixes | ~3KB | ~150 |
| `01-trajectory-generation.md` | Script usage | ~4KB | ~200 |
| `02-deployment.md` | Deployment procedures | ~5KB | ~250 |
| `03-evaluation.md` | Evaluation guidelines | ~4KB | ~200 |
| `04-complete-process.md` | Complete workflow | ~5KB | ~250 |
| `README.md` | Overview | ~2KB | ~100 |

**Total:** ~23KB of focused, modular documentation

**Coverage:**
- ✅ Critical fixes with checksums
- ✅ Complete usage examples
- ✅ Troubleshooting guides
- ✅ Deployment procedures
- ✅ Verification commands
- ✅ Best practices

---

## **When Rules Are Most Useful**

### **For You (Project Owner):**
- 🔄 Working on project after a break (rules remind you of process)
- 🔄 Debugging issues (rules have troubleshooting)
- 🔄 Scaling to new instances (rules have deployment commands)

### **For Team Members:**
- 🆕 New team member onboarding
- 🆕 Running evaluations for first time
- 🆕 Understanding critical fixes

### **For Claude Code:**
- 🤖 Answering questions accurately
- 🤖 Preventing common mistakes
- 🤖 Providing consistent guidance
- 🤖 Generating correct commands

---

## **Summary**

### **What We Built:**
A **knowledge base** that Claude Code automatically uses to:
- Answer questions correctly
- Prevent mistakes proactively
- Provide consistent guidance
- Onboard team members instantly

### **How It Works:**
1. You ask Claude a question
2. Claude reads relevant `.claude/rules/*.md` files
3. Claude provides accurate answer with context
4. No need to search docs manually

### **Key Benefit:**
**Institutional knowledge is now embedded in the codebase** and accessible to anyone using Claude Code in this project.

---

## **Quick Test**

Try asking Claude Code:

1. "What are the critical fixes I must maintain?"
   → Should reference `00-critical-fixes.md`

2. "How do I deploy to a new instance?"
   → Should reference `02-deployment.md`

3. "What's the correct script for trajectory generation?"
   → Should reference `01-trajectory-generation.md`

**If Claude references these files, the rules are working! ✅**

---

**The rules are now part of your project and will help anyone working on VeloraHarness.**
