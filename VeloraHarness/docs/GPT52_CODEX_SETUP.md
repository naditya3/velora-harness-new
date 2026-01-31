# GPT-5.2-codex Configuration for VeloraHarness

## Overview

This document describes the setup and configuration of GPT-5.2-codex with high reasoning effort in VeloraHarness for local testing.

## Configuration Summary

### Model Information
- **Model Name**: `gpt-5.2-codex`
- **Provider**: OpenAI
- **Documentation**: [GPT-5 Codex Prompting Guide](https://cookbook.openai.com/examples/gpt-5/codex_prompting_guide)

### Configuration Details

The GPT-5.2-codex configuration is located in `config.toml` under the `[llm.gpt_codex]` section:

```toml
[llm.gpt_codex]
model = "gpt-5.2-codex"
api_key = "YOUR_OPENAI_API_KEY_HERE"  # ← ADD YOUR KEY
reasoning_effort = "high"
temperature = 0.2
max_input_tokens = 120000
max_output_tokens = 65536
```

### Reasoning Effort Parameter

GPT-5.2-codex supports three levels of reasoning effort:

| Level | Description | Use Case |
|-------|-------------|----------|
| `medium` | Balanced option | Recommended for interactive coding and most tasks |
| `high` | Enhanced reasoning | More challenging tasks (current configuration) |
| `xhigh` | Maximum reasoning | The hardest problems |

**Current Setting**: `high` - Suitable for complex SWE-Bench tasks requiring deep analysis

## Setup Instructions

### 1. Add Your API Key

Edit `/Users/macbookpro/Documents/SWE_Bench/Velora_SWE_Harness/VeloraHarness/config.toml`:

```toml
[llm.gpt_codex]
api_key = "sk-..." # Replace with your actual OpenAI API key
```

### 2. Verify Configuration

Run the validation script:

```bash
cd /Users/macbookpro/Documents/SWE_Bench/Velora_SWE_Harness/VeloraHarness
python test_gpt_codex_config_simple.py
```

Expected output: "Configuration Test: PASSED"

### 3. Test with Simple Task

Run a single test instance:

```bash
cd /Users/macbookpro/Documents/SWE_Bench/Velora_SWE_Harness/VeloraHarness

python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent_cls CodeActAgent \
    --llm_config gpt_codex \
    --max_iterations 200 \
    --dataset data/test_task.jsonl \
    --split test \
    --eval_n_limit 1 \
    --eval_num_workers 1
```

## Best Practices (from OpenAI Documentation)

### 1. Prompting Strategy
- Start with the "standard Codex-Max prompt" as your base
- Make targeted additions specific to your use case
- The VeloraHarness prompts are already optimized for this

### 2. Tool Usage
- **DO**: Use dedicated tools (`apply_patch`, `shell_command`, `git`)
- **DON'T**: Use raw cmd/terminal commands when a dedicated tool exists
- VeloraHarness CodeActAgent follows this pattern

### 3. Parallelization
- Batch file reads and tool calls together using `multi_tool_use.parallel`
- Maximizes efficiency over sequential execution
- VeloraHarness supports this through its agent architecture

### 4. Autonomy Settings
- Configure the agent to work independently
- Once given direction, it should proactively:
  - Gather context
  - Plan implementation
  - Implement changes
  - Test the solution
  - Refine without waiting for additional prompts
- VeloraHarness agents are designed for autonomous operation

### 5. Token Efficiency
- Use "medium" for most interactive workflows
- Reserve "high" for complex tasks (current setting)
- Use "xhigh" sparingly for the most difficult problems

## Testing Strategy

### Local Testing (Current Phase)

1. **Configuration Validation** ✓
   - Config file syntax is correct
   - All required parameters are present
   - Values match expected formats

2. **Simple Task Test** (Next Step)
   - Run with `data/test_task.jsonl`
   - Verify API connectivity
   - Check that reasoning_effort parameter is passed correctly
   - Confirm Docker image handling

3. **Full Task Test** (After Simple Test)
   - Use more complex task from sample_task.jsonl
   - Monitor reasoning behavior
   - Check output quality

### What to Monitor

1. **API Calls**
   - Check LLM completion logs in `eval_output_dir/llm_completions/`
   - Verify `reasoning_effort: "high"` is present in API requests

2. **Performance Metrics**
   - Number of iterations used
   - Token consumption (input/output)
   - Time per task
   - Success rate on test tasks

3. **Error Handling**
   - API rate limits
   - Token limit issues
   - Docker image availability

## Configuration Options

### Adjust Reasoning Effort

To change the reasoning level, edit `config.toml`:

```toml
[llm.gpt_codex]
reasoning_effort = "medium"  # or "high" or "xhigh"
```

### Adjust Max Iterations

Edit the core configuration:

```toml
[core]
max_iterations = 200  # Increase for more complex tasks
```

### Adjust Temperature

For more deterministic output:

```toml
[llm.gpt_codex]
temperature = 0.0  # More deterministic (current: 0.2)
```

For more creative solutions:

```toml
[llm.gpt_codex]
temperature = 0.5  # More creative
```

## Troubleshooting

### Issue: "Invalid API key"
**Solution**: Ensure your OpenAI API key is correctly set in config.toml

### Issue: "Model not found"
**Solution**: Verify you have access to GPT-5.2-codex through your OpenAI account

### Issue: "reasoning_effort parameter not recognized"
**Solution**: Check that you're using a version of the OpenAI API that supports this parameter

### Issue: Docker image not found
**Solution**:
- For local testing without Docker images, set `USE_INSTANCE_IMAGE=false`
- Or ensure Docker images are available locally

## Next Steps

### After Local Testing Succeeds

1. **Gather Baseline Metrics**
   - Run 5-10 tasks from sample dataset
   - Document success rate, token usage, time per task
   - Compare with other models (Claude, GPT-5.1, etc.)

2. **Optimize Configuration**
   - Adjust reasoning_effort based on task complexity
   - Fine-tune temperature if needed
   - Optimize max_iterations

3. **AWS Deployment** (Future)
   - **DO NOT** deploy to AWS yet (as per instructions)
   - Wait for local testing results
   - Document any configuration changes needed

## Files Modified

1. **config.toml** - Added `[llm.gpt_codex]` section
2. **test_gpt_codex_config_simple.py** - Validation script (new)
3. **GPT52_CODEX_SETUP.md** - This documentation (new)

## Research Findings

### From OpenAI Cookbook

1. **Model Identifier**: `gpt-5.2-codex`
2. **Reasoning Effort Values**: "medium", "high", "xhigh"
3. **Recommended Approach**: Start with standard Codex-Max prompt
4. **Key Feature**: Supports parallel tool execution
5. **Best For**: Complex coding tasks requiring deep reasoning

### Integration Notes

- VeloraHarness uses LiteLLM for API calls
- The `reasoning_effort` parameter is passed through to the OpenAI API
- LLMConfig class handles parameter validation
- Config is loaded via `get_llm_config_arg(args.llm_config)`

## Contact & Support

For issues or questions:
1. Check OpenAI documentation: https://cookbook.openai.com/examples/gpt-5/codex_prompting_guide
2. Review VeloraHarness logs in the eval output directory
3. Consult team members for configuration assistance

---

**Last Updated**: 2026-01-29
**Configuration Version**: v1.0
**Status**: Ready for Local Testing
