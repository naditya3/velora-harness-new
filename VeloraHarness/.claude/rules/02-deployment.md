# Deployment Guidelines

**Purpose:** Deploy VeloraHarness fixes to AWS instances
**Last Updated:** 2026-01-23

---

## **Deployment Strategy**

### **Hybrid Approach (Recommended)**

Use **OpenHands installations** on instances as base + **VeloraHarness fixes**

**Why:**
- ✅ OpenHands has working Poetry environments
- ✅ OpenHands has all dependencies installed
- ✅ OpenHands has `multi_swe_bench/run_infer.py` already
- ✅ Just need to copy 4 fixed files

**Alternative (Not Recommended):**
- Deploy complete VeloraHarness and fix Poetry environment
- More complex, requires debugging Poetry virtualenv issues

---

## **Deployment Commands**

### **Deploy to Single Instance:**

```bash
INSTANCE="eval1"  # Change for each instance

# Navigate to VeloraHarness on local machine
cd /Users/macbookpro/Documents/SWE_Bench/Velora_SWE_Harness/VeloraHarness

# 1. Copy main pipeline script
scp evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh \
  aws-instance-$INSTANCE:~/SWETEs7/OpenHands/evaluation/benchmarks/multi_swe_bench/scripts/

# 2. Copy evaluation script
scp evaluation/benchmarks/multi_swe_bench/scripts/eval_pilot2_standardized.py \
  aws-instance-$INSTANCE:~/SWETEs7/OpenHands/evaluation/benchmarks/multi_swe_bench/scripts/

# 3. Copy Docker builder fix
scp openhands/runtime/builder/docker.py \
  aws-instance-$INSTANCE:~/SWETEs7/OpenHands/openhands/runtime/builder/

# 4. Copy Dockerfile template
scp openhands/runtime/utils/runtime_templates/Dockerfile.j2 \
  aws-instance-$INSTANCE:~/SWETEs7/OpenHands/openhands/runtime/utils/runtime_templates/

# 5. Make script executable
ssh aws-instance-$INSTANCE "chmod +x ~/SWETEs7/OpenHands/evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh"

# 6. Verify checksums
ssh aws-instance-$INSTANCE bash << 'VERIFY'
cd ~/SWETEs7/OpenHands

echo "Verifying deployed files..."

# Expected checksums (as of 2026-01-23)
declare -A expected=(
  ["evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh"]="fe08d93ed67b76c21e59b9d84e07ba36"
  ["evaluation/benchmarks/multi_swe_bench/scripts/eval_pilot2_standardized.py"]="c71b963ae19398e900681ec2340da445"
  ["openhands/runtime/builder/docker.py"]="c719fdafa6102198c8068f530846cac3"
  ["openhands/runtime/utils/runtime_templates/Dockerfile.j2"]="6edc931ce32b967dd50dc91d7f08551f"
)

all_match=true
for file in "${!expected[@]}"; do
  if [ -f "$file" ]; then
    actual=$(md5sum "$file" | cut -d' ' -f1)
    if [ "$actual" = "${expected[$file]}" ]; then
      echo "✓ $file"
    else
      echo "✗ $file - CHECKSUM MISMATCH"
      echo "  Expected: ${expected[$file]}"
      echo "  Actual: $actual"
      all_match=false
    fi
  else
    echo "✗ $file - NOT FOUND"
    all_match=false
  fi
done

if [ "$all_match" = true ]; then
  echo ""
  echo "✅ All files verified successfully"
else
  echo ""
  echo "❌ Some files have issues - redeploy needed"
fi
VERIFY
```

---

### **Deploy to All 10 Instances:**

```bash
cd /Users/macbookpro/Documents/SWE_Bench/Velora_SWE_Harness/VeloraHarness

# Loop through all instances
for INSTANCE in eval1 eval2 eval3 eval4 eval5 eval6 eval9 lancer1 lancer2 lancer3; do
  echo ""
  echo "=========================================="
  echo "Deploying to aws-instance-$INSTANCE"
  echo "=========================================="

  # Copy all 4 files
  scp evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh \
    aws-instance-$INSTANCE:~/SWETEs7/OpenHands/evaluation/benchmarks/multi_swe_bench/scripts/

  scp evaluation/benchmarks/multi_swe_bench/scripts/eval_pilot2_standardized.py \
    aws-instance-$INSTANCE:~/SWETEs7/OpenHands/evaluation/benchmarks/multi_swe_bench/scripts/

  scp openhands/runtime/builder/docker.py \
    aws-instance-$INSTANCE:~/SWETEs7/OpenHands/openhands/runtime/builder/

  scp openhands/runtime/utils/runtime_templates/Dockerfile.j2 \
    aws-instance-$INSTANCE:~/SWETEs7/OpenHands/openhands/runtime/utils/runtime_templates/

  # Make executable
  ssh aws-instance-$INSTANCE "chmod +x ~/SWETEs7/OpenHands/evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh"

  echo "✓ Deployed to $INSTANCE"
done

echo ""
echo "=========================================="
echo "Deployment Complete"
echo "=========================================="
```

---

## **Post-Deployment Verification**

### **Quick Test on Each Instance:**

```bash
INSTANCE="eval1"

ssh aws-instance-$INSTANCE bash << 'TEST'
cd ~/SWETEs7/OpenHands

export PATH="$HOME/.local/bin:$PATH"

echo "=== Quick Verification Test ==="

# 1. Check Poetry works
poetry run python -c "import openhands.agenthub; print('✓ Poetry environment OK')" || echo "✗ Poetry issue"

# 2. Check files exist
[ -f "evaluation/benchmarks/multi_swe_bench/scripts/run_full_eval_with_s3.sh" ] && echo "✓ run_full_eval_with_s3.sh" || echo "✗ MISSING"
[ -f "evaluation/benchmarks/multi_swe_bench/scripts/eval_pilot2_standardized.py" ] && echo "✓ eval_pilot2_standardized.py" || echo "✗ MISSING"
[ -f "openhands/runtime/builder/docker.py" ] && echo "✓ docker.py" || echo "✗ MISSING"
[ -f "openhands/runtime/utils/runtime_templates/Dockerfile.j2" ] && echo "✓ Dockerfile.j2" || echo "✗ MISSING"

# 3. Check critical fixes
grep -q "Use legacy builder" openhands/runtime/builder/docker.py && echo "✓ DOCKER_BUILDKIT=0 fix present" || echo "✗ Fix MISSING"
grep -q "tmux" openhands/runtime/utils/runtime_templates/Dockerfile.j2 && echo "✓ tmux fix present" || echo "✗ Fix MISSING"

# 4. Check disk space
df -h / | awk 'NR==2 {print "Disk free: " $4}'

echo "✓ Instance ready"
TEST
```

---

## **AWS Instance List**

| Instance | SSH Alias | IP Address | Status |
|----------|-----------|------------|--------|
| eval1 | aws-instance-eval1 | - | ✅ Deployed & Verified |
| eval2 | aws-instance-eval2 | - | ⏳ Pending |
| eval3 | aws-instance-eval3 | - | ⏳ Pending |
| eval4 | aws-instance-eval4 | - | ⏳ Pending |
| eval5 | aws-instance-eval5 | - | ⏳ Pending |
| eval6 | aws-instance-eval6 | - | ⏳ Pending |
| eval9 | aws-instance-eval9 | - | ⏳ Pending |
| lancer1 | aws-instance-lancer1 | - | ⏳ Pending |
| lancer2 | aws-instance-lancer2 | - | ⏳ Pending |
| lancer3 | aws-instance-lancer3 | - | ⏳ Pending |

---

## **Rollback Procedure**

If deployment causes issues:

```bash
INSTANCE="eval1"

# Restore from backup (if created)
ssh aws-instance-$INSTANCE bash << 'ROLLBACK'
cd ~/SWETEs7/OpenHands

# Restore files if backups exist
for file in openhands/runtime/builder/docker.py \
            openhands/runtime/utils/runtime_templates/Dockerfile.j2; do
  if [ -f "${file}.backup" ]; then
    cp "${file}.backup" "$file"
    echo "Restored $file"
  fi
done
ROLLBACK
```

---

## **Deployment Log**

Keep track of deployments:

```bash
# Create deployment log
echo "$(date): Deployed to $INSTANCE - checksums verified" >> ~/deployment_log.txt
```

---

## **Critical Reminders**

- ✅ Always use **multi_swe_bench** paths
- ✅ Always deploy **all 4 files** together
- ✅ Always verify **checksums** after deployment
- ✅ Always test with **small dataset** first
- ✅ Always use **OpenHands** as base (not VeloraHarness_Test)
