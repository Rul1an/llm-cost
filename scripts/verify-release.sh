#!/bin/bash
set -e

# Verify Release Artifacts Script
# Usage: ./scripts/verify-release.sh <artifact_name> <tag>

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <artifact-name> <tag>"
    echo "Example: $0 llm-cost-linux-x86_64 v0.7.0"
    exit 1
fi

ARTIFACT=$1
TAG=$2
REPO="Rul1an/llm-cost"

echo "🔍 Downloading $ARTIFACT from $TAG..."
if ! command -v gh &> /dev/null; then
    echo "Error: GitHub CLI (gh) is not installed."
    exit 1
fi

gh release download "$TAG" -p "$ARTIFACT" --repo "$REPO" --clobber

echo "🛡️  Verifying attestation for $ARTIFACT..."
gh attestation verify "$ARTIFACT" --repo "$REPO"

echo "✅ Verification Successful! The artifact is genuine and untampered."
