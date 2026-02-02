# Docker Image Creation & Evaluation Manual Process

> This document describes the step-by-step manual process for creating Docker images and evaluating F2P/P2P tests for each task in the SWE benchmark dataset.

---

## Pre-requisites

### Tools Required
- Docker installed and running
- Git with GitHub access
- `gh` CLI authenticated (for fetching PR refs)

### Data Files Location
- Task data: `VeloraHarness/data/client_tasks_10_evaluable.jsonl`
- Output folder: `VeloraHarness/evaluation_results/{instance_id}/`

---

## Process Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PHASE 1: DOCKER IMAGE CREATION (Manual)                   │
├─────────────────────────────────────────────────────────────────────────────┤
│  1. Create Docker container (language-specific base)                        │
│  2. Clone repo inside container                                             │
│  3. Fetch PR refs and compute commits                                       │
│  4. Verify base_commit matches our data                                     │
│  5. Checkout to base_commit                                                 │
│  6. Install dependencies (language-specific)                                │
│  7. Run tests → Fix environment issues → Repeat until F2P fails, P2P passes │
│  8. SAVE DOCKER IMAGE (at base commit state)                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                 PHASE 2: EVALUATION (Automated Script)                       │
├─────────────────────────────────────────────────────────────────────────────┤
│  9. Run: python evaluate_task.py --task-file tasks.jsonl --instance-id X    │
│     (Script automatically: applies patch → runs tests → parses output)      │
│ 10. Review results in evaluation_results/                                   │
│ 11. Verify against our data, flag mismatches                                │
│ 12. Cleanup                                                                 │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Why "Apply Patch" Instead of "Git Checkout Merge Commit"?

| Criteria | Merge Commit Checkout | Apply Patch (Recommended) |
|----------|----------------------|---------------------------|
| **Network Required** | Yes (git fetch) | No (patch in JSONL) |
| **Speed** | Slower (network IO) | Faster (local file) |
| **Reliability** | Depends on GitHub | Fully reproducible |
| **Offline Capable** | No | Yes |
| **PR might be deleted** | Will fail | Still works |

The `patch` field in JSONL contains the exact PR diff. We use `git apply` to apply it.

---

## Detailed Steps

### Step 1: Create Docker Container (Language-Specific Base)

Start an interactive Docker container with the appropriate language runtime.

#### Base Images by Language

| Language | Base Image | Notes |
|----------|------------|-------|
| **Go** | `golang:{version}` | Use version from `go.mod` |
| **Java** | `maven:{version}` or `gradle:{version}` | Check for pom.xml vs build.gradle |
| **Rust** | `rust:{version}` | Use version from `rust-toolchain.toml` |
| **JavaScript** | `node:{version}` | Use version from `.nvmrc` or `package.json` |
| **PHP** | `php:{version}` | Use version from `composer.json` |
| **Ruby** | `ruby:{version}` | Use version from `.ruby-version` or `Gemfile` |

#### Commands

```bash
# Example for Go
docker run -it --name {instance_id} golang:1.21 /bin/bash

# Example for JavaScript
docker run -it --name {instance_id} node:18 /bin/bash

# Example for Java (Maven)
docker run -it --name {instance_id} maven:3.9-eclipse-temurin-17 /bin/bash

# Example for Ruby
docker run -it --name {instance_id} ruby:3.2 /bin/bash

# Example for PHP
docker run -it --name {instance_id} php:8.2-cli /bin/bash

# Example for Rust
docker run -it --name {instance_id} rust:1.75 /bin/bash
```

**Note:** Use slim/alpine variants where possible to minimize image size.

---

### Step 2: Clone Repository Inside Container

```bash
# Inside the container
cd /app  # or /testbed - choose a consistent working directory
git clone https://github.com/{owner}/{repo}.git repo
cd repo
```

---

### Step 3: Fetch PR Refs and Compute Commits

```bash
# Get PR number from instance_id (e.g., "owner__repo.pr_123" → 123)
PR_NUMBER={extracted_from_instance_id}

# Fetch PR refs
git fetch origin refs/pull/${PR_NUMBER}/head:pr_head
git fetch origin refs/pull/${PR_NUMBER}/merge:pr_merge 2>/dev/null || true

# Get the target branch (usually main/master)
TARGET_BRANCH=$(git remote show origin | grep 'HEAD branch' | cut -d' ' -f5)

# Compute base commit (where PR diverged from target branch)
BASE_COMMIT=$(git merge-base origin/${TARGET_BRANCH} pr_head)

# PR commit is the PR head (or merge commit if available)
PR_COMMIT=$(git rev-parse pr_head)

# Display for verification
echo "Computed base_commit: ${BASE_COMMIT}"
echo "Computed pr_commit: ${PR_COMMIT}"
```

---

### Step 4: Verify base_commit Matches Our Data

```bash
# Compare with data file (outside container)
# Expected base_commit from data: {base_commit_from_jsonl}

# Inside container, verify:
echo "Computed: ${BASE_COMMIT}"
echo "Expected: {base_commit_from_jsonl}"

# If mismatch: FLAG FOR INVESTIGATION
# Record in: evaluation_results/{instance_id}/MISMATCH_base_commit.txt
```

**Action on Mismatch:**
- Create file `MISMATCH_base_commit.txt` with both values
- Continue with computed base_commit but flag for later review

---

### Step 5: Checkout to Base Commit

```bash
git checkout ${BASE_COMMIT}

# Verify
git log -1 --oneline
```

---

### Step 6: Install Dependencies (Language-Specific)

#### Go
```bash
go mod download
# or
go mod tidy && go mod download
```

#### Java (Maven)
```bash
mvn dependency:resolve -DskipTests
# or full compile without tests
mvn compile -DskipTests
```

#### Java (Gradle)
```bash
./gradlew dependencies --no-daemon
# or
./gradlew assemble -x test
```

#### Rust
```bash
cargo fetch
# or
cargo build --release
```

#### JavaScript (npm)
```bash
npm ci
# or if no package-lock.json
npm install
```

#### JavaScript (yarn)
```bash
yarn install --frozen-lockfile
# or
yarn install
```

#### JavaScript (pnpm)
```bash
pnpm install --frozen-lockfile
```

#### PHP
```bash
composer install --no-interaction
```

#### Ruby
```bash
bundle install
```

---

### Step 7: Run Tests and Fix Environment Issues

#### 7a. Run Tests (Language-Specific Commands)

| Language | Test Command | Output Format |
|----------|--------------|---------------|
| **Go** | `go test ./... -v -json > test_output.json` | JSON |
| **Java (Maven)** | `mvn test -Dsurefire.useFile=false` | JUnit XML in `target/surefire-reports/` |
| **Java (Gradle)** | `./gradlew test` | JUnit XML in `build/test-results/` |
| **Rust** | `cargo test -- --test-threads=1 2>&1 \| tee test_output.txt` | Text |
| **JavaScript** | `npm test -- --json > test_output.json` | Varies (Jest JSON, Mocha, etc.) |
| **PHP** | `./vendor/bin/phpunit --log-junit test_output.xml` | JUnit XML |
| **Ruby** | `bundle exec rspec --format json > test_output.json` | JSON |

#### 7b. Analyze Test Results

**Expected at Base Commit:**
- F2P tests: MUST FAIL (these are the tests that the PR fixes)
- P2P tests: MUST PASS (these are existing tests that should not break)

**If tests don't run at all (environment errors):**
1. Document the error
2. Fix the environment issue (missing dependencies, config, etc.)
3. Document the fix in `setup_commands.sh`
4. Re-run tests

#### 7c. Common Environment Fixes

```bash
# Missing system dependencies
apt-get update && apt-get install -y {package}

# Missing test config
cp config.example.yaml config.yaml

# Database setup for integration tests
# (varies by project)

# Permission issues
chmod +x scripts/*.sh
```

#### 7d. Iterate Until Success

```
LOOP:
  1. Run tests
  2. If environment error → fix and document → GOTO 1
  3. If F2P tests PASS → something is wrong, investigate
  4. If P2P tests FAIL → might be environment issue, investigate
  5. If F2P FAIL and P2P PASS → SUCCESS, proceed to Step 8
```

---

### Step 8: SAVE DOCKER IMAGE (Critical Step)

**IMPORTANT:** Save the Docker image NOW, at the base commit state with all environment fixes applied.

```bash
# Exit the container (but don't remove it)
exit

# Outside the container - commit the container state as an image
docker commit {instance_id} velora/{instance_id}:base

# Verify the image was created
docker images | grep {instance_id}

# Optional: Tag with more info
docker tag velora/{instance_id}:base velora/{instance_id}:base_${BASE_COMMIT:0:12}
```

**Image Contents at This Point:**
- Language runtime (Go, Java, Rust, JS, PHP, Ruby)
- Cloned repository at base_commit
- All dependencies installed
- Environment fixes applied
- F2P tests fail, P2P tests pass

---

### Step 9: Run Automated Evaluation Script

**After saving the Docker image, evaluation is automated!**

```bash
# Run evaluation for a single task
python evaluate_task.py \
    --task-file ../data/client_tasks_10_evaluable.jsonl \
    --instance-id "{instance_id}"

# Or run for all tasks with images
python evaluate_task.py \
    --task-file ../data/client_tasks_10_evaluable.jsonl \
    --all
```

**What the Script Does:**
1. Starts a fresh container from your saved image (`velora/{instance_id}:base`)
2. Applies the `patch` field from JSONL using `git apply`
3. Runs the `test_command` from JSONL
4. Parses output using the appropriate language parser
5. Compares results against F2P/P2P expected tests
6. Generates report

**Script Location:** `VeloraHarness/harness/evaluate_task.py`

---

### Step 10: Review Evaluation Results

Check the output in `evaluation_results/`:

```bash
# View results summary
cat evaluation_results/evaluation_results.jsonl | python -m json.tool

# View raw test output for a specific task
cat evaluation_results/{instance_id}_test_output.txt
```

**Expected Results:**
- F2P tests: MUST PASS NOW (the patch fixed these)
- P2P tests: MUST STILL PASS (no regressions)

**Status Values:**
- `SUCCESS`: All F2P passed, all P2P passed
- `PARTIAL`: Some F2P passed, or all P2P passed
- `FAILED`: Patch failed to apply, or tests didn't run

---

### Step 11: Verify Against Our Data

The script compares actual results against expected F2P/P2P from JSONL.

**Check for mismatches:**
```bash
# View the evaluation result
cat evaluation_results/evaluation_results.jsonl | \
  jq 'select(.instance_id == "{instance_id}")'
```

**Mismatch Indicators:**
- `f2p_actual_failed` is not empty → Some F2P tests didn't pass after patch
- `p2p_actual_failed` is not empty → Some P2P tests regressed

**If Mismatch Found:**
```bash
# Create mismatch report
echo "Expected F2P: {from JSONL}" > evaluation_results/{instance_id}/MISMATCH.txt
echo "Actual F2P passed: {from results}" >> evaluation_results/{instance_id}/MISMATCH.txt
```

**Mismatch Handling:**
- DO NOT automatically update the data
- Create mismatch report for manual review
- Possible reasons:
  - Test names use different format
  - Test discovery differs
  - Data was incorrect

---

### Step 12: Cleanup

```bash
# Stop the container (keep it for potential re-investigation)
docker stop {instance_id}

# Optional: Remove container after confirming results
# docker rm {instance_id}

# Keep the saved image
# velora/{instance_id}:base
```

---

## Output Files Structure

```
VeloraHarness/
├── evaluation_results/
│   └── {instance_id}/
│       ├── evaluation_result.jsonl      # Main results
│       ├── test_output_base.json        # Test output at base commit
│       ├── test_output_pr.json          # Test output at PR commit
│       ├── setup_commands.sh            # Environment fixes applied
│       ├── MISMATCH_base_commit.txt     # (if applicable)
│       └── MISMATCH_f2p_tests.txt       # (if applicable)
└── docker_images/
    └── {instance_id}/
        └── Dockerfile                   # For reproducibility
```

---

## Language-Specific Test Parsing

### Go
```bash
# Parse JSON test output
cat test_output.json | jq -r 'select(.Action=="fail") | .Test' | sort -u > failed_tests.txt
cat test_output.json | jq -r 'select(.Action=="pass") | .Test' | sort -u > passed_tests.txt
```

### Java (JUnit XML)
```bash
# Parse surefire reports
grep -r 'failure' target/surefire-reports/*.xml
```

### JavaScript (Jest)
```bash
# Parse Jest JSON output
cat test_output.json | jq '.testResults[].assertionResults[] | select(.status=="failed") | .fullName'
```

### PHP (PHPUnit)
```bash
# Parse JUnit XML
grep -E '<(failure|error)' test_output.xml
```

### Ruby (RSpec)
```bash
# Parse RSpec JSON output
cat test_output.json | jq '.examples[] | select(.status=="failed") | .full_description'
```

### Rust
```bash
# Parse text output
grep -E "^test .* FAILED$" test_output.txt
```

---

## Checklist Per Task

- [ ] Container created with correct language version
- [ ] Repo cloned successfully
- [ ] PR refs fetched
- [ ] base_commit computed and verified
- [ ] Checkout to base_commit done
- [ ] Dependencies installed
- [ ] Environment issues fixed (if any)
- [ ] Tests run at base_commit
- [ ] F2P tests FAIL at base_commit
- [ ] P2P tests PASS at base_commit
- [ ] **Docker image SAVED**
- [ ] Checkout to pr_commit done
- [ ] Tests run at pr_commit
- [ ] F2P tests PASS at pr_commit
- [ ] P2P tests PASS at pr_commit
- [ ] Results recorded
- [ ] Verified against data
- [ ] Mismatches flagged (if any)
- [ ] Cleanup done

---

## Troubleshooting

### Test Discovery Issues
- Some frameworks need specific flags to discover tests
- Check the project's CI/CD config for test commands

### Timeout Issues
- Some tests might need longer timeouts
- Use `--timeout` flags where available

### Flaky Tests
- Run tests multiple times
- Check for race conditions or external dependencies

### Missing Test Dependencies
- Some tests need additional setup (databases, fixtures)
- Check the project's test documentation

---

## Notes

1. **Always save the Docker image at Step 8** - This is the evaluable artifact
2. **Don't modify the saved image with PR changes** - PR checkout is only for evaluation
3. **Flag mismatches, don't auto-fix** - Manual review ensures data quality
4. **Document all environment fixes** - For reproducibility
5. **Keep containers until results verified** - Allows re-investigation
