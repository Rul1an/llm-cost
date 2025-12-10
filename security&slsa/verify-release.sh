#!/bin/bash
# verify-release.sh - Verify llm-cost release artifacts
#
# Usage:
#   ./scripts/verify-release.sh llm-cost-linux-x86_64
#   ./scripts/verify-release.sh llm-cost-linux-x86_64 v1.0.0
#
# Requirements:
#   - GitHub CLI (gh) OR Cosign
#   - curl

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

REPO="Rul1an/llm-cost"
ARTIFACT="${1:-}"
VERSION="${2:-latest}"

usage() {
    echo "Usage: $0 <artifact> [version]"
    echo ""
    echo "Examples:"
    echo "  $0 llm-cost-linux-x86_64"
    echo "  $0 llm-cost-linux-x86_64 v1.0.0"
    echo ""
    echo "Artifacts:"
    echo "  llm-cost-linux-x86_64"
    echo "  llm-cost-linux-arm64"
    echo "  llm-cost-macos-arm64"
    echo "  llm-cost-macos-x86_64"
    echo "  llm-cost-windows-x86_64.exe"
    exit 1
}

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

check_tools() {
    local has_gh=false
    local has_cosign=false
    
    if command -v gh &> /dev/null; then
        has_gh=true
    fi
    
    if command -v cosign &> /dev/null; then
        has_cosign=true
    fi
    
    if ! $has_gh && ! $has_cosign; then
        error "Neither 'gh' nor 'cosign' found. Install one of them:
  - GitHub CLI: https://cli.github.com/
  - Cosign: https://docs.sigstore.dev/cosign/installation/"
    fi
    
    echo "$has_gh:$has_cosign"
}

get_release_url() {
    local version="$1"
    local artifact="$2"
    
    if [ "$version" = "latest" ]; then
        echo "https://github.com/${REPO}/releases/latest/download/${artifact}"
    else
        echo "https://github.com/${REPO}/releases/download/${version}/${artifact}"
    fi
}

download_if_needed() {
    local url="$1"
    local file="$2"
    
    if [ ! -f "$file" ]; then
        info "Downloading $file..."
        curl -fsSL -o "$file" "$url" || error "Failed to download $file"
    else
        info "Using existing $file"
    fi
}

verify_with_gh() {
    local artifact="$1"
    
    info "Verifying with GitHub CLI..."
    
    if gh attestation verify "$artifact" --repo "$REPO"; then
        echo ""
        echo -e "${GREEN}✓ Verification PASSED${NC}"
        echo ""
        echo "The artifact was built by the official CI pipeline."
        return 0
    else
        echo ""
        echo -e "${RED}✗ Verification FAILED${NC}"
        echo ""
        echo "The artifact may have been tampered with or is not from the official source."
        return 1
    fi
}

verify_with_cosign() {
    local artifact="$1"
    local version="$2"
    
    info "Verifying with Cosign..."
    
    # Download signature and certificate
    local base_url
    if [ "$version" = "latest" ]; then
        base_url="https://github.com/${REPO}/releases/latest/download"
    else
        base_url="https://github.com/${REPO}/releases/download/${version}"
    fi
    
    download_if_needed "${base_url}/${artifact}.sig" "${artifact}.sig"
    download_if_needed "${base_url}/${artifact}.crt" "${artifact}.crt"
    
    if cosign verify-blob \
        --signature "${artifact}.sig" \
        --certificate "${artifact}.crt" \
        --certificate-identity-regexp "https://github.com/${REPO}" \
        --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
        "$artifact"; then
        echo ""
        echo -e "${GREEN}✓ Verification PASSED${NC}"
        echo ""
        echo "The artifact signature is valid."
        return 0
    else
        echo ""
        echo -e "${RED}✗ Verification FAILED${NC}"
        echo ""
        echo "The artifact signature is invalid or the certificate doesn't match."
        return 1
    fi
}

verify_checksum() {
    local artifact="$1"
    local version="$2"
    
    info "Verifying checksum..."
    
    local base_url
    if [ "$version" = "latest" ]; then
        base_url="https://github.com/${REPO}/releases/latest/download"
    else
        base_url="https://github.com/${REPO}/releases/download/${version}"
    fi
    
    download_if_needed "${base_url}/SHA256SUMS.txt" "SHA256SUMS.txt"
    
    if sha256sum -c SHA256SUMS.txt --ignore-missing 2>/dev/null | grep -q "OK"; then
        echo -e "${GREEN}✓ Checksum OK${NC}"
        return 0
    else
        echo -e "${RED}✗ Checksum FAILED${NC}"
        return 1
    fi
}

show_sbom() {
    local artifact="$1"
    local version="$2"
    
    local base_url
    if [ "$version" = "latest" ]; then
        base_url="https://github.com/${REPO}/releases/latest/download"
    else
        base_url="https://github.com/${REPO}/releases/download/${version}"
    fi
    
    local sbom_file="${artifact}.cdx.json"
    
    if download_if_needed "${base_url}/${sbom_file}" "${sbom_file}" 2>/dev/null; then
        info "SBOM available: ${sbom_file}"
        
        if command -v jq &> /dev/null; then
            echo ""
            echo "Components:"
            jq -r '.components[]?.name // "No components listed"' "$sbom_file" 2>/dev/null || true
        fi
    else
        warn "SBOM not available for this artifact"
    fi
}

main() {
    if [ -z "$ARTIFACT" ]; then
        usage
    fi
    
    echo "╔════════════════════════════════════════════╗"
    echo "║     llm-cost Release Verification Tool     ║"
    echo "╚════════════════════════════════════════════╝"
    echo ""
    echo "Artifact: $ARTIFACT"
    echo "Version:  $VERSION"
    echo "Repo:     $REPO"
    echo ""
    
    # Check for required tools
    local tools
    tools=$(check_tools)
    local has_gh="${tools%%:*}"
    local has_cosign="${tools##*:}"
    
    # Download artifact if needed
    local artifact_url
    artifact_url=$(get_release_url "$VERSION" "$ARTIFACT")
    download_if_needed "$artifact_url" "$ARTIFACT"
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Verify using available tools
    local verified=false
    
    if [ "$has_gh" = "true" ]; then
        if verify_with_gh "$ARTIFACT"; then
            verified=true
        fi
    elif [ "$has_cosign" = "true" ]; then
        if verify_with_cosign "$ARTIFACT" "$VERSION"; then
            verified=true
        fi
    fi
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Always verify checksum as backup
    verify_checksum "$ARTIFACT" "$VERSION" || true
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Show SBOM info
    show_sbom "$ARTIFACT" "$VERSION"
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    if $verified; then
        echo -e "${GREEN}VERIFICATION COMPLETE: Artifact is authentic${NC}"
        exit 0
    else
        echo -e "${RED}VERIFICATION FAILED: Do not use this artifact${NC}"
        exit 1
    fi
}

main "$@"
