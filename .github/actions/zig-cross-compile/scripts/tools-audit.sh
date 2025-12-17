#!/usr/bin/env bash
set -euo pipefail

# tools-audit.sh
# Installs supply chain security tools (Syft, Cosign) with pinned versions.
# Currently restricted to Linux x86_64 runners to ensure binary compatibility.

TOOL="$1"
INSTALL_PREFIX="${HOME}/.local/bin"
mkdir -p "$INSTALL_PREFIX"
export PATH="$INSTALL_PREFIX:$PATH"

log() { echo "::notice::[tools-audit] $1"; }
die() { echo "::error::[tools-audit] $1"; exit 1; }

# OS/Arch Validation
OS=$(uname -s)
ARCH=$(uname -m)

if [[ "$OS" != "Linux" ]]; then
    die "Supply chain tools (Syft/Cosign) are currently only supported on Linux runners. Current OS: $OS"
fi

if [[ "$ARCH" != "x86_64" ]]; then
    die "Supply chain tools (Syft/Cosign) are currently only supported on x86_64. Current Arch: $ARCH"
fi

case "$TOOL" in
    syft)
        VERSION="v1.0.1"
        if command -v syft >/dev/null; then
            log "Syft already installed."
        else
            log "Installing Syft $VERSION..."
            curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b "$INSTALL_PREFIX" "$VERSION"
        fi
        ;;
    cosign)
        VERSION="v2.2.3"
        if command -v cosign >/dev/null; then
             log "Cosign already installed."
        else
             log "Installing Cosign $VERSION..."
             curl -fL "https://github.com/sigstore/cosign/releases/download/${VERSION}/cosign-linux-amd64" -o "$INSTALL_PREFIX/cosign"
             chmod +x "$INSTALL_PREFIX/cosign"
        fi
        ;;
    *)
        die "Unknown tool: $TOOL"
        ;;
esac
