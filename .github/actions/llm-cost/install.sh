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
cleanup() { rm -rf "${TMP_DIR}"; }
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

# ... (middle parts unchanged) ...

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
