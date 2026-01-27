# VeloraHarness Project Rules

**Purpose:** Modular, topic-specific guidelines for trajectory generation and evaluation
**Format:** Claude Code compatible `.claude/rules/*.md`
**Last Updated:** 2026-01-23

---

## **Rules Organization**

### **00-critical-fixes.md**
**Topic:** Code that MUST be maintained
**Contains:**
- 4 critical fixes with checksums
- DOCKER_BUILDKIT=0 support
- tmux in Dockerfile.j2
- Dataset parsing fix
- AST-based list parsing
- Verification commands

**Use when:** Deploying to new instances, merging upstream changes

---

### **01-trajectory-generation.md**
**Topic:** Running trajectory generation successfully
**Contains:**
- Correct script to use (`run_full_eval_with_s3.sh`)
- Script parameters and usage
- Environment variables
- Expected output structure
- Troubleshooting guide
- Common mistakes

**Use when:** Running trajectory generation, debugging failures

---

### **02-deployment.md**
**Topic:** Deploying VeloraHarness to AWS instances
**Contains:**
- Hybrid deployment strategy
- Step-by-step deployment commands
- Checksum verification
- Deploy to all 10 instances script
- Post-deployment testing
- Rollback procedure

**Use when:** Setting up new instances, updating existing deployments

---

### **03-evaluation.md**
**Topic:** Evaluation process and requirements
**Contains:**
- Two evaluation approaches (full pipeline vs eval-only)
- eval_pilot2_standardized.py usage
- Client harness requirements
- Docker image requirements
- Success criteria
- Common issues and solutions
- Batch evaluation process

**Use when:** Running evaluations, debugging test failures

---

## **Quick Reference**

### **For Trajectory Generation:**
```bash
# Read first:
cat .claude/rules/01-trajectory-generation.md

# Verify critical fixes:
cat .claude/rules/00-critical-fixes.md | grep "Verification:"

# Run:
./evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh \
  llm.gpt /path/to/dataset.jsonl 1 200 1
```

### **For Deployment:**
```bash
# Read deployment guide:
cat .claude/rules/02-deployment.md

# Run deployment:
# (Follow commands in section "Deploy to All 10 Instances")
```

### **For Evaluation Only:**
```bash
# Read evaluation guide:
cat .claude/rules/03-evaluation.md

# Run evaluation:
python3 evaluation/benchmarks/multi_swe_bench/scripts/eval_pilot2_standardized.py \
  --trajectory-file output.jsonl \
  --dataset-file dataset.jsonl \
  --docker-image mswebench/... \
  --output-file result.jsonl \
  --timeout 600
```

---

## **File Checksums (Consistency Verification)**

**As of 2026-01-23:**

| File | MD5 Checksum |
|------|--------------|
| `run_full_eval_with_s3.sh` | `fe08d93ed67b76c21e59b9d84e07ba36` |
| `eval_pilot2_standardized.py` | `c71b963ae19398e900681ec2340da445` |
| `docker.py` | `c719fdafa6102198c8068f530846cac3` |
| `Dockerfile.j2` | `6edc931ce32b967dd50dc91d7f08551f` |

**Verify with:**
```bash
cd /Users/macbookpro/Documents/SWE_Bench/Velora_SWE_Harness/VeloraHarness
md5 -r evaluation/benchmarks/multi_swe_bench/scripts/*.sh \
       evaluation/benchmarks/multi_swe_bench/scripts/*.py \
       openhands/runtime/builder/docker.py \
       openhands/runtime/utils/runtime_templates/Dockerfile.j2
```

---

## **Integration with Claude Code**

These rules are automatically discovered by Claude Code when working in this repository.

**To update rules:**
1. Edit the appropriate `.md` file in `.claude/rules/`
2. Commit changes to git
3. Rules are shared via source control with team

**Best practices:**
- Keep rules modular (one topic per file)
- Use numbered prefixes for ordering (00-, 01-, 02-)
- Include practical examples and commands
- Update checksums when files change
- Keep synchronized with actual code

---

## **Consistency Status**

**Local Repository:**
- Location: `/Users/macbookpro/Documents/SWE_Bench/Velora_SWE_Harness/VeloraHarness/`
- All 4 critical files: ✅ Present with correct checksums
- Rules directory: ✅ Created

**AWS Instance eval1:**
- Location: `~/SWETEs7/OpenHands/`
- All 4 critical files: ✅ Deployed and verified (checksums match)
- Test run: ✅ Complete (68KB patch, eval_outputs/ created)

**Other 9 Instances:**
- Status: ⏳ Pending deployment
- Required: Copy 4 files from local VeloraHarness

---

## **Maintenance**

### **When OpenHands Updates:**
1. Check if any of the 4 critical files changed
2. Re-apply fixes if overwritten
3. Update checksums in `00-critical-fixes.md`
4. Test on one instance before deploying to all

### **When Rules Change:**
1. Update appropriate `.md` file
2. Test changes on one instance
3. Update checksums if code changed
4. Commit to git for team sharing

### **Regular Verification:**
Run consistency check monthly:
```bash
cd VeloraHarness
./scripts/verify_consistency.sh
```

---

## **Related Documentation**

- `OPENHANDS_VELORA_HARNESS_MEMORY.md` - Complete technical reference
- `COMPLETE_PIPELINE_VERIFIED.md` - Verified output structure
- `FILE_MANIFEST.md` - How VeloraHarness was created
- `.cursorrules` - Workspace-level rules (deprecated, moved here)

---

**All rules are version controlled and team-shared via git.**
