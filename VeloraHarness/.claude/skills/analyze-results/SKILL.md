---
name: analyze-results
description: Analyze SWE-bench evaluation results and token usage
allowed-tools: Bash, Read, Grep, Glob
argument-hint: [output-directory]
---

# Analyze Evaluation Results

Parse and summarize SWE-bench evaluation outputs.

## Find Latest Results
```bash
EVAL_DIR="${ARGUMENTS:-$(ls -td /home/ubuntu/velora/VeloraHarness/evaluation/evaluation_outputs/outputs/*/* 2>/dev/null | head -1)}"
echo "Analyzing: $EVAL_DIR"
```

## Analysis Steps

### 1. Check Output Files
```bash
ls -la "$EVAL_DIR/"
```

### 2. Parse Trajectory Output
```bash
if [ -f "$EVAL_DIR/output.jsonl" ]; then
    echo "=== Trajectory Summary ==="
    cat "$EVAL_DIR/output.jsonl" | python3 -c "
import json, sys
for line in sys.stdin:
    d = json.loads(line)
    print(f\"Instance: {d.get('instance_id', 'unknown')}\")
    print(f\"Error: {d.get('error', 'None')}\")
    patch = d.get('git_patch', '')
    print(f\"Patch size: {len(patch)} bytes\")
    print(f\"History length: {len(d.get('history', []))}\")
"
fi
```

### 3. Parse Evaluation Results
```bash
if [ -f "$EVAL_DIR/output.swebench_eval.jsonl" ]; then
    echo "=== Evaluation Results ==="
    cat "$EVAL_DIR/output.swebench_eval.jsonl" | python3 -c "
import json, sys
for line in sys.stdin:
    d = json.loads(line)
    print(f\"Instance: {d.get('instance_id', 'unknown')}\")
    print(f\"Resolved: {d.get('resolved', False)}\")
    print(f\"Tests passed: {d.get('tests_passed', 0)}\")
    print(f\"Tests failed: {d.get('tests_failed', 0)}\")
"
fi
```

### 4. Token Usage Analysis
```bash
echo "=== Token Usage ==="
find "$EVAL_DIR/llm_completions" -name "*.json" 2>/dev/null | while read f; do
    python3 -c "
import json
with open('$f') as f:
    d = json.load(f)
    usage = d.get('model_response', {}).get('usage', {})
    if usage:
        print(f\"Input: {usage.get('input_tokens', 'N/A')}\")
        print(f\"Output: {usage.get('output_tokens', 'N/A')}\")
        details = usage.get('output_tokens_details', {})
        if details:
            print(f\"Reasoning: {details.get('reasoning_tokens', 'N/A')}\")
" 2>/dev/null
done | head -20
```

### 5. Error Summary
```bash
echo "=== Errors ==="
grep -r "error\|Error\|ERROR" "$EVAL_DIR"/*.log 2>/dev/null | tail -10
```

## Output Report

Summarize:
- Total tasks evaluated
- Pass/fail rate
- Average token usage
- Common errors
- Recommendations for improvement
