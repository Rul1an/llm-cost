export default {
	async fetch(request) {
		if (request.method !== "GET" && request.method !== "HEAD") {
			return new Response("Method Not Allowed", { status: 405 });
		}

		const script = `#!/bin/sh
set -eu

# llm-cost Installer (Self-healing SOTA)
# Usage:
#   curl -sSfL https://get.llm-cost.dev | sh
#   LLM_COST_VERSION=v1.1.1 ...
#
# Env:
#   LLM_COST_REPO=Owner/Repo
#   LLM_COST_VERSION=latest|vX.Y.Z
#   LLM_COST_INSTALL_DIR=/path/bin
#   LLM_COST_SHA256=<pin>

REPO="\${LLM_COST_REPO:-Rul1an/llm-cost}"
VERSION="\${LLM_COST_VERSION:-latest}"
PIN_SHA256="\${LLM_COST_SHA256:-}"
INSTALL_DIR="\${LLM_COST_INSTALL_DIR:-}"

error() { echo "Error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || error "Missing: $1"; }

need curl
need uname

# Probe URL existence (HEAD request)
url_exists() {
  curl -fSsI --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 10 "$1" >/dev/null 2>&1
}

resolve_platform_and_asset() {
  OS_RAW="\$(uname -s 2>/dev/null || true)"
  ARCH_RAW="\$(uname -m 2>/dev/null || true)"

  # Define candidate aliases
  case "\$OS_RAW" in
    Linux)  OS_CANDS="linux" ;;
    Darwin) OS_CANDS="macos darwin" ;; # Probe both (legacy=macos, new=darwin)
    *) error "Unsupported OS: \$OS_RAW" ;;
  esac

  case "\$ARCH_RAW" in
    x86_64|amd64) ARCH_CANDS="x86_64 amd64" ;;
    aarch64|arm64) ARCH_CANDS="arm64 aarch64" ;;
    *) error "Unsupported arch: \$ARCH_RAW" ;;
  esac

  SUFFIX=""
  if [ "\$OS_RAW" = "Linux" ] && [ -f /etc/alpine-release ]; then
    SUFFIX="-musl"
  fi

  # Resolve Base URL
  if [ "\$VERSION" = "latest" ]; then
    BASE="https://github.com/\${REPO}/releases/latest/download"
  else
    BASE="https://github.com/\${REPO}/releases/download/\${VERSION}"
  fi

  # Probe candidates
  echo "Probing for assets..." >&2
  for o in \$OS_CANDS; do
    for a in \$ARCH_CANDS; do
       CAND="llm-cost-\${o}-\${a}\${SUFFIX}"
       if url_exists "\$BASE/\$CAND"; then
          ASSET="\$CAND"
          echo "Found compatible asset: \$ASSET"
          return 0
       fi
    done
  done

  error "No asset found for \$OS_RAW/\$ARCH_RAW in release \$VERSION"
}

curl_get() {
  curl -fSsL --proto '=https' --tlsv1.2 \\
    --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 60 \\
    "\$1" -o "\$2"
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    set -- \$(shasum -a 256 "\$1"); echo "\$1"
  elif command -v sha256sum >/dev/null 2>&1; then
    set -- \$(sha256sum "\$1"); echo "\$1"
  else
    error "No sha256 util found"
  fi
}

pick_install_dir() {
  if [ -n "\$INSTALL_DIR" ]; then return 0; fi
  if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
    INSTALL_DIR="/usr/local/bin"
  else
    INSTALL_DIR="\${HOME:-/tmp}/.local/bin"
  fi
}

mktemp_dir() {
  td="\${TMPDIR:-/tmp}"
  d="\$(mktemp -d "\${td%/}/llm-cost.XXXXXX" 2>/dev/null || true)"
  if [ -z "\$d" ]; then
    d="\${td%/}/llm-cost.\$\$"
    mkdir -p "\$d" || error "Failed to create temp dir"
  fi
  echo "\$d"
}

extract_expected_checksum() {
  sums_file="\$1"
  expected=""
  while IFS= read -r line; do
    set -- \$line || continue
    h="\$1"; f="\${2:-}"
    [ -n "\$h" ] || continue
    [ -n "\$f" ] || continue
    f="\${f#\\*}"
    if [ "\$f" = "\$ASSET" ]; then expected="\$h"; break; fi
  done < "\$sums_file"
  [ -n "\$expected" ] || error "Checksum NOT found for \$ASSET"
  echo "\$expected"
}

main() {
  umask 077

  resolve_platform_and_asset  # Sets ASSET and BASE

  pick_install_dir
  mkdir -p "\$INSTALL_DIR" 2>/dev/null || true

  TMP="\$(mktemp_dir)"
  trap 'rm -rf "\$TMP"' EXIT

  BIN="\$TMP/\$ASSET"
  SUM="\$TMP/checksums.txt"

  echo "Downloading \$ASSET (\$VERSION)..."
  curl_get "\$BASE/\$ASSET" "\$BIN"

  if [ -n "\$PIN_SHA256" ]; then
    EXPECTED="\$PIN_SHA256"
  else
    curl_get "\$BASE/checksums.txt" "\$SUM"
    EXPECTED="\$(extract_expected_checksum "\$SUM")"
  fi

  ACTUAL="\$(sha256_file "\$BIN")"
  [ "\$EXPECTED" = "\$ACTUAL" ] || error "Checksum mismatch! Exp: \$EXPECTED Got: \$ACTUAL"

  chmod 0755 "\$BIN"

  DEST="\$INSTALL_DIR/llm-cost"
  if [ -w "\$INSTALL_DIR" ]; then
    mv "\$BIN" "\$DEST"
  elif command -v sudo >/dev/null 2>&1; then
    sudo mv "\$BIN" "\$DEST"
  else
    error "Cannot install to \$INSTALL_DIR (permission denied; no sudo)"
  fi

  echo "✓ Installed to \$DEST"
  echo "  Tip: run 'llm-cost --help'"
  if [ "\$INSTALL_DIR" = "\${HOME:-}/.local/bin" ]; then
    echo "  Ensure ~/.local/bin is on PATH"
  fi
}

main
`;

		return new Response(script, {
			headers: {
				"content-type": "text/plain; charset=utf-8",
				"cache-control": "public, max-age=300",
				"x-content-type-options": "nosniff",
			},
		});
	},
};
