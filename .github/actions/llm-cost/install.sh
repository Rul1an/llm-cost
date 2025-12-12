#!/usr/bin/env bash
set -euo pipefail

REPO="${LLM_COST_REPO:-Rul1an/llm-cost}"
VERSION="${LLM_COST_VERSION:-latest}"
VERIFY="${LLM_COST_VERIFY:-true}"
PIN_SHA256="${LLM_COST_SHA256:-}"

# Prefer runner temp, fallback for local dev
RUNNER_TMP="${RUNNER_TEMP:-}"
if [ -z "${RUNNER_TMP}" ]; then
  RUNNER_TMP="$(pwd)/.llm-cost-tmp"
  mkdir -p "${RUNNER_TMP}"
fi

TMP_DIR="$(mktemp -d "${RUNNER_TMP%/}/llm-cost.XXXXXX")"
cleanup() { [ -d "${TMP_DIR:-}" ] && rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "::error::Missing required command: $1"
    exit 1
  }
}

need_cmd curl
need_cmd uname

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "::error::Neither 'shasum' nor 'sha256sum' is available on this runner."
    exit 1
  fi
}

gh_api_get() {
  local url="$1"
  local curl_opts=(curl -fsSL -L --retry 3 --retry-all-errors --connect-timeout 10 --max-time 120)
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    "${curl_opts[@]}" \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      "$url"
  else
    "${curl_opts[@]}" -H "Accept: application/vnd.github+json" "$url"
  fi
}

detect_os_arch() {
  local os
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "${os}" in
    linux) OS="linux" ;;
    darwin) OS="macos" ;;
    mingw*|msys*) OS="windows" ;;
    *)
      echo "::error::Unsupported OS: ${os}"
      exit 1
      ;;
  esac

  local arch
  arch="$(uname -m | tr '[:upper:]' '[:lower:]')"
  case "${arch}" in
    x86_64|amd64) ARCH="x86_64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *)
      echo "::error::Unsupported Architecture: ${arch}"
      exit 1
      ;;
  esac

  # Map to llm-cost binary suffix
  # linux-x86_64, linux-x86_64-musl, linux-arm64, macos-arm64, windows-x86_64.exe
  # standard macos x86_64 not supported in current release matrix (only arm64 macos) but code might support it?
  # Matrix: macos-latest (arm64 for 14+?), target=aarch64-macos.
  # If user is on Intel Mac ...? We don't have a release asset for it in release.yml!
  # release.yml has: x86_64-linux-gnu, x86_64-linux-musl, aarch64-linux-gnu, x86_64-windows-gnu, aarch64-macos.
  # So Intel Mac is NOT supported.

  if [ "${OS}" = "macos" ] && [ "${ARCH}" = "x86_64" ]; then
     echo "::error::Intel macOS (x86_64) is not currently supported by pre-built binaries."
     exit 1
  fi

  # Determine ASSET name
  # llm-cost-<suffix>
  # Suffixes:
  # linux-x86_64
  # linux-arm64
  # macos-arm64
  # windows-x86_64.exe

  local suffix=""
  if [ "${OS}" = "windows" ]; then
    suffix="windows-${ARCH}.exe"
  else
    suffix="${OS}-${ARCH}"
  fi

  ASSET="llm-cost-${suffix}"

  # release_assets/llm-cost-<suffix>
  # We need the binary name for URL.
  # URL structure: https://github.com/OWNER/REPO/releases/download/TAG/llm-cost-<suffix>

  if [ "${VERSION}" = "latest" ]; then
     # Resolved later
     bindownload_url=""
  else
     BIN_URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"
     CHECKSUMS_URL="https://github.com/${REPO}/releases/download/${VERSION}/checksums.txt"
  fi
}

detect_os_arch

echo "::notice::Installing llm-cost ${VERSION} (${OS}/${ARCH}) from ${REPO}"

CURL=(curl -fsSL -L --retry 3 --retry-all-errors --connect-timeout 10 --max-time 120)
"${CURL[@]}" "${BIN_URL}" -o "${TMP_DIR}/${ASSET}"
chmod +x "${TMP_DIR}/${ASSET}"

EXPECTED=""
if [ -n "${PIN_SHA256}" ]; then
  EXPECTED="${PIN_SHA256}"
else
  # Prefer checksums.txt if published with the release
  if "${CURL[@]}" "${CHECKSUMS_URL}" -o "${TMP_DIR}/checksums.txt"; then
    # SOTA: match plain filename OR *filename (GNU style)
    EXPECTED="$(
      awk -v a="${ASSET}" '
        $2==a {print $1; exit}
        $2=="*"a {print $1; exit}
      ' "${TMP_DIR}/checksums.txt"
    )"
  fi
fi

ACTUAL="$(sha256_file "${TMP_DIR}/${ASSET}")"

if [ "${VERIFY}" = "true" ]; then
  if [ -z "${EXPECTED}" ]; then
    echo "::error::Checksum verification is enabled but no expected sha256 is available."
    echo "::error::Publish 'checksums.txt' in the release OR pass inputs.sha256."
    exit 1
  fi
  if [ "${ACTUAL}" != "${EXPECTED}" ]; then
    echo "::error::SHA256 mismatch for ${ASSET}"
    echo "::error::Expected: ${EXPECTED}"
    echo "::error::Actual:   ${ACTUAL}"
    exit 1
  fi
  echo "::notice::SHA256 verified (${ACTUAL})"
else
  echo "::warning::Checksum verification disabled. Actual sha256: ${ACTUAL}"
fi

INSTALL_DIR="${RUNNER_TEMP:-${RUNNER_TMP}}/llm-cost/bin"
mkdir -p "${INSTALL_DIR}"
cp "${TMP_DIR}/${ASSET}" "${INSTALL_DIR}/llm-cost"
chmod +x "${INSTALL_DIR}/llm-cost"

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "${INSTALL_DIR}" >> "${GITHUB_PATH}"
fi

echo "::notice::llm-cost installed to ${INSTALL_DIR}/llm-cost"
