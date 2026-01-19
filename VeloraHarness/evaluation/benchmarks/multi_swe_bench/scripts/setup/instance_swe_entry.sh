#!/bin/bash

source ~/.bashrc
SWEUTIL_DIR=/swe_util

# FIXME: Cannot read SWE_INSTANCE_ID from the environment variable
# SWE_INSTANCE_ID=django__django-11099
if [ -z "$SWE_INSTANCE_ID" ]; then
    echo "Error: SWE_INSTANCE_ID is not set." >&2
    exit 1
fi

if [ -z "$REPO_NAME" ]; then
    echo "Error: REPO_NAME is not set." >&2
    exit 1
fi

# Read the swe-bench-test-lite.json file and extract the required item based on instance_id
item=$(jq --arg INSTANCE_ID "$SWE_INSTANCE_ID" '.[] | select(.instance_id == $INSTANCE_ID)' $SWEUTIL_DIR/eval_data/instances/swe-bench-instance.json)

if [[ -z "$item" ]]; then
  echo "No item found for the provided instance ID."
  exit 1
fi

# Handle null version by falling back to instance_id
VERSION=$(echo "$item" | jq -r '.version // .instance_id')
if [ "$VERSION" == "null" ] || [ -z "$VERSION" ]; then
    VERSION=$(echo "$item" | jq -r '.instance_id')
fi
WORKSPACE_NAME=$(echo "$item" | jq -r --arg ver "$VERSION" '(.repo | tostring) + "__" + $ver | gsub("/"; "__")')

echo "WORKSPACE_NAME: $WORKSPACE_NAME"

# Clear the workspace
if [ -d /workspace ]; then
    rm -rf /workspace/*
else
    mkdir /workspace
fi
# Copy repo to workspace
if [ -d /workspace/$WORKSPACE_NAME ]; then
    rm -rf /workspace/$WORKSPACE_NAME
fi
mkdir -p /workspace

# Source repo location differs across images
# Check multiple locations where repos might be stored (handles non-standard Docker images)
# Extract just the repo name (e.g., "sway" from "swaywm/sway")
REPO_SHORT_NAME=$(echo "$REPO_NAME" | sed 's|.*/||')

REPO_FOUND=false
REPO_LOCATIONS=(
    "/home/$REPO_NAME"
    "/testbed"
    "/app/repo"
    "/src/$REPO_SHORT_NAME"
    "/go/src/$REPO_SHORT_NAME"
    "/workspace/$REPO_SHORT_NAME"
    "/root/$REPO_SHORT_NAME"
)

for loc in "${REPO_LOCATIONS[@]}"; do
    if [ -d "$loc" ]; then
        echo "Found repo at $loc, copying to workspace..."
        cp -r "$loc" "/workspace/$WORKSPACE_NAME"
        REPO_FOUND=true
        break
    fi
done

if [ "$REPO_FOUND" = false ]; then
    echo "Source code not found in image, attempting to clone from GitHub..."
    
    # Extract repo URL and base commit from the instance data
    REPO_URL=$(echo "$item" | jq -r '.repo // empty')
    BASE_COMMIT=$(echo "$item" | jq -r '.base_commit // .environment_setup_commit // empty')
    
    if [ -z "$REPO_URL" ] || [ "$REPO_URL" == "null" ]; then
        echo "Error: could not find source repo at /home/$REPO_NAME or /testbed, and no repo URL in instance data" >&2
        exit 1
    fi
    
    # Convert repo name (e.g., "leejet/stable-diffusion.cpp") to GitHub URL if needed
    if [[ ! "$REPO_URL" =~ ^https?:// ]]; then
        REPO_URL="https://github.com/${REPO_URL}.git"
    fi
    
    echo "Cloning $REPO_URL..."
    git clone "$REPO_URL" "/workspace/$WORKSPACE_NAME"
    
    if [ $? -ne 0 ]; then
        echo "Error: failed to clone repository from $REPO_URL" >&2
    exit 1
    fi
    
    # Checkout the base commit if specified
    if [ -n "$BASE_COMMIT" ] && [ "$BASE_COMMIT" != "null" ]; then
        echo "Checking out commit $BASE_COMMIT..."
        cd "/workspace/$WORKSPACE_NAME"
        git checkout "$BASE_COMMIT"
        if [ $? -ne 0 ]; then
            echo "Warning: failed to checkout commit $BASE_COMMIT, using default branch"
        fi
    fi
    
    echo "Successfully cloned and set up repository"
fi

# Activate instance-specific environment
# . /opt/miniconda3/etc/profile.d/conda.sh
# conda activate testbed
