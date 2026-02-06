#!/bin/bash
# Script to push code to new GitHub repository

set -e

GITHUB_USERNAME="naditya3"
REPO_NAME="velora-harness-new"  # Change if you want different name
NEW_REPO_URL="https://github.com/${GITHUB_USERNAME}/${REPO_NAME}.git"

echo "==============================================="
echo "  Pushing to New GitHub Repository"
echo "==============================================="
echo ""
echo "Repository: ${NEW_REPO_URL}"
echo ""

# Check current git status
echo "📊 Current git status:"
git status --short | head -20

echo ""
echo "⚠️  IMPORTANT: Make sure you've already created the repository at:"
echo "   https://github.com/${GITHUB_USERNAME}/${REPO_NAME}"
echo ""
read -p "Have you created the repository? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Please create the repository first at: https://github.com/new"
    echo "   Then run this script again."
    exit 1
fi

# Add new remote
echo ""
echo "🔗 Adding new remote..."
if git remote get-url new-repo 2>/dev/null; then
    echo "Remote 'new-repo' already exists, removing it..."
    git remote remove new-repo
fi
git remote add new-repo "${NEW_REPO_URL}"

echo "✓ Remote added: new-repo -> ${NEW_REPO_URL}"

# Show all remotes
echo ""
echo "📋 Current remotes:"
git remote -v

# Push to new repository
echo ""
echo "🚀 Pushing all branches and history to new repository..."
echo "   This may take a few minutes..."
echo ""

# Push main branch
git push -u new-repo main

# Push all branches (if any)
# git push new-repo --all

# Push tags (if any)
# git push new-repo --tags

echo ""
echo "✅ SUCCESS! Code pushed to new repository"
echo ""
echo "🌐 View your new repository at:"
echo "   https://github.com/${GITHUB_USERNAME}/${REPO_NAME}"
echo ""
echo "📝 To make this the default remote, run:"
echo "   git remote rename origin old-origin"
echo "   git remote rename new-repo origin"
echo ""
