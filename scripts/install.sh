#!/bin/sh
set -eu

# llm-cost Installer (hardened, dumb)
# Usage:
#   curl -sSfL https://get.llm-cost.dev | sh
#   LLM_COST_VERSION=v1.1.1 curl -sSfL https://get.llm-cost.dev | sh
#   LLM_COST_SHA256=<expected_hash> curl -sSfL https://get.llm-cost.dev | sh
#
# Env:
#   LLM_COST_REPO=Owner/Repo
#   LLM_COST_VERSION=latest|vX.Y.Z
#   LLM_COST_INSTALL_DIR=/path/bin
#   LLM_COST_SHA256=<pin>

REPO="${LLM_COST_REPO:-Rul1an/llm-cost}"
VERSION="${LLM_COST_VERSION:-latest}"
PIN_SHA256="${LLM_COST_SHA256:-}"
INSTALL_DIR="${LLM_COST_INSTALL_DIR:-}"

error() { echo "Error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || error "Missing: $1"; }

need curl
need uname

detect_platform() {
  OS="$(uname -s 2>/dev/null || true)"
  ARCH="$(uname -m 2>/dev/null || true)"

  case "$OS" in
    Linux)  OS="linux" ;;
    Darwin) OS="darwin" ;;  # MUST match release asset naming
    *) error "Unsupported OS: $OS" ;;
  esac

  case "$ARCH" in
    x86_64|amd64) ARCH="x86_64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) error "Unsupported arch: $ARCH" ;;
  esac

  SUFFIX=""
  if [ "$OS" = "linux" ] && [ -f /etc/alpine-release ]; then
    SUFFIX="-musl"
  fi

  ASSET="llm-cost-${OS}-${ARCH}${SUFFIX}"
}

curl_get() {
  # -f: fail on HTTP errors, -S: show error, -s: silent, -L: follow redirects
  # --proto '=https' & --tlsv1.2 are standard hardening flags.
  curl -fSsL --proto '=https' --tlsv1.2 \
    --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 120 \
    "$1" -o "$2"
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    set -- $(shasum -a 256 "$1"); echo "$1"
  elif command -v sha256sum >/dev/null 2>&1; then
    set -- $(sha256sum "$1"); echo "$1"
  else
    error "No sha256 util found (need shasum or sha256sum)"
  fi
}

resolve_base_url() {
  # Official GitHub pattern for latest asset download:
  # /releases/latest/download/<asset>
  if [ "$VERSION" = "latest" ]; then
    BASE="https://github.com/${REPO}/releases/latest/download"
  else
    BASE="https://github.com/${REPO}/releases/download/${VERSION}"
  fi
}

pick_install_dir() {
  if [ -n "$INSTALL_DIR" ]; then
    return 0
  fi

  if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
    INSTALL_DIR="/usr/local/bin"
  else
    INSTALL_DIR="${HOME:-/tmp}/.local/bin"
  fi
}

mktemp_dir() {
  td="${TMPDIR:-/tmp}"
  d="$(mktemp -d "${td%/}/llm-cost.XXXXXX" 2>/dev/null || true)"
  if [ -z "$d" ]; then
    d="${td%/}/llm-cost.$$"
    mkdir -p "$d" || error "Failed to create temp dir"
  fi
  echo "$d"
}

extract_expected_checksum() {
  sums_file="$1"
  expected=""

  # Accept:
  #   <hash>  filename
  #   <hash> *filename
  while IFS= read -r line; do
    set -- $line || continue
    h="$1"
    f="${2:-}"
    [ -n "$h" ] || continue
    [ -n "$f" ] || continue
    f="${f#\*}"
    if [ "$f" = "$ASSET" ]; then
      expected="$h"
      break
    fi
  done < "$sums_file"

  [ -n "$expected" ] || error "Checksum NOT found for $ASSET"
  echo "$expected"
}

main() {
  # Keep temp private; fix final perms explicitly with chmod 0755.
  umask 077

  detect_platform
  resolve_base_url
  pick_install_dir

  mkdir -p "$INSTALL_DIR" 2>/dev/null || true

  TMP="$(mktemp_dir)"
  trap 'rm -rf "$TMP"' EXIT

  BIN="$TMP/$ASSET"
  SUM="$TMP/checksums.txt"

  echo "Downloading $ASSET ($VERSION)..."
  curl_get "$BASE/$ASSET" "$BIN"

  if [ -n "$PIN_SHA256" ]; then
    EXPECTED="$PIN_SHA256"
  else
    curl_get "$BASE/checksums.txt" "$SUM"
    EXPECTED="$(extract_expected_checksum "$SUM")"
  fi

  ACTUAL="$(sha256_file "$BIN")"
  [ "$EXPECTED" = "$ACTUAL" ] || error "Checksum mismatch! Expected: $EXPECTED Got: $ACTUAL"

  chmod 0755 "$BIN"

  DEST="$INSTALL_DIR/llm-cost"
  if [ -w "$INSTALL_DIR" ]; then
    mv "$BIN" "$DEST"
  elif command -v sudo >/dev/null 2>&1; then
    sudo mv "$BIN" "$DEST"
  else
    error "Cannot install to $INSTALL_DIR (permission denied; no sudo)"
  fi

  echo "✓ Installed to $DEST"
  echo "  Tip: run 'llm-cost --help'"
  if [ "$INSTALL_DIR" = "${HOME:-}/.local/bin" ]; then
    echo "  Ensure ~/.local/bin is on PATH"
  fi
}

main
