#!/bin/bash
# Test temperature verification in the main script
# Just run the prerequisite validation part

set -eo pipefail

PROJECT_ROOT="/home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness"
MODELS=("opus" "gpt" "kimi" "qwen")

echo "Testing temperature verification..."
echo ""

config_file="${PROJECT_ROOT}/config.toml"
if [[ -f "${config_file}" ]]; then
    echo "Verifying temperature settings in config.toml..."
    
    temp_issues=0
    for model in "${MODELS[@]}"; do
        temp=$(grep -A 10 "\[llm.${model}\]" "${config_file}" | grep "^temperature" | awk '{print $3}')
        if [[ -n "${temp}" ]]; then
            if [[ "${temp}" != "1.0" ]]; then
                echo "  ⚠️  Model '${model}' has temperature=${temp} (expected 1.0)"
                temp_issues=$((temp_issues + 1))
            else
                echo "  ✓ Model '${model}' temperature=${temp}"
            fi
        else
            echo "  ⚠️  Could not verify temperature for model '${model}'"
        fi
    done
    
    echo ""
    if [[ ${temp_issues} -eq 0 ]]; then
        echo "✅ All models configured with temperature=1.0"
    else
        echo "⚠️  ${temp_issues} model(s) have non-standard temperature settings"
    fi
fi
