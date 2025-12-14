#!/usr/bin/env bash
set -euo pipefail

ZIG_VERSION="${ZIG_VERSION:-0.14.0}"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "${OS}" in
  linux)   OS="linux" ;;
  darwin)  OS="macos" ;;
  msys*|mingw*|cygwin*) OS="windows" ;;
esac

case "${ARCH}" in
  x86_64|amd64) ARCH="x86_64" ;;
  arm64|aarch64) ARCH="aarch64" ;;
esac

WORK="${RUNNER_TEMP:-/tmp}/zig-${ZIG_VERSION}"
mkdir -p "${WORK}"
cd "${WORK}"

if [ "${OS}" = "windows" ]; then
  echo "Windows runner: use PowerShell install in workflow (see ci.yml)."
  exit 1
fi

TARBALL="zig-${OS}-${ARCH}-${ZIG_VERSION}.tar.xz"
URL="https://ziglang.org/download/${ZIG_VERSION}/${TARBALL}"

echo "Downloading ${URL}"
curl -fsSLO "${URL}"
tar -xf "${TARBALL}"

ZIG_DIR="$(find . -maxdepth 1 -type d -name "zig-${OS}-${ARCH}-${ZIG_VERSION}" | head -n1)"
echo "${WORK}/${ZIG_DIR}" >> "${GITHUB_PATH:-/dev/null}"

echo "Zig installed:"
"${WORK}/${ZIG_DIR}/zig" version
