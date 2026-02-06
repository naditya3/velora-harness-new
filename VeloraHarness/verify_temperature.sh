#!/usr/bin/env bash
################################################################################
# Temperature Configuration Verification and Update Script
#
# Verifies and optionally updates temperature settings for all models in
# config.toml to ensure they are set to 1.0
#
# Usage:
#   ./verify_temperature.sh              # Check only
#   ./verify_temperature.sh --fix        # Check and fix
#   ./verify_temperature.sh --set 0.7    # Set specific temperature
#
# Author: Expert Coder
# Date: 2026-02-06
################################################################################

set -eo pipefail

# Absolute paths
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_FILE="${SCRIPT_DIR}/config.toml"
readonly BACKUP_DIR="${SCRIPT_DIR}/config_backups"

# Default temperature
DEFAULT_TEMPERATURE=1.0

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Parse arguments
FIX_MODE=false
CUSTOM_TEMP=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --fix)
            FIX_MODE=true
            shift
            ;;
        --set)
            CUSTOM_TEMP="$2"
            FIX_MODE=true
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --fix          Fix temperature settings to 1.0"
            echo "  --set TEMP     Set specific temperature value"
            echo "  --help, -h     Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                  # Verify only"
            echo "  $0 --fix            # Fix to 1.0"
            echo "  $0 --set 0.7        # Set to 0.7"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Set target temperature
TARGET_TEMP="${CUSTOM_TEMP:-$DEFAULT_TEMPERATURE}"

# Verify config file exists
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo -e "${RED}❌ Config file not found: ${CONFIG_FILE}${NC}"
    exit 1
fi

echo "================================================================================"
echo "  Temperature Configuration Verification"
echo "================================================================================"
echo "Config file: ${CONFIG_FILE}"
echo "Target temperature: ${TARGET_TEMP}"
echo "Mode: $([ "$FIX_MODE" = true ] && echo "FIX" || echo "CHECK ONLY")"
echo ""

# Models to check
MODELS=("opus" "sonnet" "gpt" "kimi" "qwen" "gemini")

# Arrays to track results
declare -a CORRECT_MODELS
declare -a INCORRECT_MODELS
declare -a MISSING_MODELS

# Check each model
echo "Checking model configurations..."
echo "--------------------------------------------------------------------------------"

for model in "${MODELS[@]}"; do
    # Extract temperature value for this model
    temp_value=$(grep -A 10 "^\[llm\.${model}\]" "${CONFIG_FILE}" | grep "^temperature" | awk '{print $3}' || echo "")

    if [[ -z "${temp_value}" ]]; then
        MISSING_MODELS+=("${model}")
        echo -e "${YELLOW}⚠️  ${model}: temperature setting not found${NC}"
    elif [[ "${temp_value}" == "${TARGET_TEMP}" ]]; then
        CORRECT_MODELS+=("${model}")
        echo -e "${GREEN}✓${NC}  ${model}: temperature=${temp_value}"
    else
        INCORRECT_MODELS+=("${model}")
        echo -e "${RED}✗${NC}  ${model}: temperature=${temp_value} (expected ${TARGET_TEMP})"
    fi
done

echo "--------------------------------------------------------------------------------"
echo ""

# Summary
echo "Summary:"
echo "  ✓ Correct: ${#CORRECT_MODELS[@]}"
echo "  ✗ Incorrect: ${#INCORRECT_MODELS[@]}"
echo "  ⚠ Missing: ${#MISSING_MODELS[@]}"
echo ""

# If all correct, exit
if [[ ${#INCORRECT_MODELS[@]} -eq 0 && ${#MISSING_MODELS[@]} -eq 0 ]]; then
    echo -e "${GREEN}✅ All models have correct temperature setting: ${TARGET_TEMP}${NC}"
    exit 0
fi

# If not in fix mode, show instructions and exit
if [[ "$FIX_MODE" != true ]]; then
    echo -e "${YELLOW}To fix these issues, run: $0 --fix${NC}"
    exit 1
fi

# Fix mode - create backup first
echo "Creating backup..."
mkdir -p "${BACKUP_DIR}"
BACKUP_FILE="${BACKUP_DIR}/config.toml.$(date +%Y%m%d_%H%M%S)"
cp "${CONFIG_FILE}" "${BACKUP_FILE}"
echo "Backup created: ${BACKUP_FILE}"
echo ""

# Fix incorrect temperatures
if [[ ${#INCORRECT_MODELS[@]} -gt 0 ]]; then
    echo "Fixing incorrect temperature settings..."

    for model in "${INCORRECT_MODELS[@]}"; do
        # Use sed to update temperature for this model
        # Find the [llm.model] section and update temperature within it
        sed -i.tmp "/^\[llm\.${model}\]/,/^\[/{
            s/^temperature = .*/temperature = ${TARGET_TEMP}/
        }" "${CONFIG_FILE}"
        rm -f "${CONFIG_FILE}.tmp"

        echo -e "${GREEN}✓${NC} Fixed ${model}: temperature=${TARGET_TEMP}"
    done
fi

# Handle missing temperatures
if [[ ${#MISSING_MODELS[@]} -gt 0 ]]; then
    echo ""
    echo "Adding missing temperature settings..."

    for model in "${MISSING_MODELS[@]}"; do
        # Find the line after [llm.model] and insert temperature
        sed -i.tmp "/^\[llm\.${model}\]/a\\
temperature = ${TARGET_TEMP}" "${CONFIG_FILE}"
        rm -f "${CONFIG_FILE}.tmp"

        echo -e "${GREEN}✓${NC} Added ${model}: temperature=${TARGET_TEMP}"
    done
fi

echo ""
echo -e "${GREEN}✅ All temperature settings updated to ${TARGET_TEMP}${NC}"
echo ""
echo "Backup location: ${BACKUP_FILE}"
echo "To restore: cp ${BACKUP_FILE} ${CONFIG_FILE}"
echo ""
echo "Verifying changes..."
echo ""

# Re-run verification
"$0"
