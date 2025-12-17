#!/usr/bin/env bash
set -euo pipefail

# setup-env.sh
# Handles target mapping and environment setup for Zig Cross-Compile Action v3.
# Sourced by action.yml steps.

# 1. Inputs (via Action Env Vars)
# github-actions converts inputs to uppercase INPUT_<NAME>
# v3 inputs:
TARGET_PRESET="${INPUT_TARGET_PRESET:-}"
# v2 legacy inputs:
ZIG_TARGET_RAW="${INPUT_ZIG_TARGET:-}" # 'target' input
PROJECT_TYPE="${INPUT_PROJECT_TYPE:-custom}"
SETUP_ONLY="${INPUT_SETUP_ONLY:-false}"

log() { echo "::notice::[setup-env] $1"; }
die() { echo "::error::[setup-env] $1"; exit 1; }

# 2. Target Resolution Strategy
# Explicit target (v2 style or overrides) wins.
if [[ -n "$ZIG_TARGET_RAW" ]]; then
    ZIG_TARGET="$ZIG_TARGET_RAW"
    # Supersedes target_preset as per v3 design spec
    log "Using explicit target: $ZIG_TARGET"
elif [[ -n "$TARGET_PRESET" ]]; then
    # v3 Preset Mapping
    case "$TARGET_PRESET" in
        linux-x86_64|linux-x86_64-gnu)   ZIG_TARGET="x86_64-linux-gnu" ;;
        linux-x86_64-musl)               ZIG_TARGET="x86_64-linux-musl" ;;
        linux-arm64|linux-aarch64)       ZIG_TARGET="aarch64-linux-gnu" ;;
        linux-arm64-musl)                ZIG_TARGET="aarch64-linux-musl" ;;
        macos-x86_64)                    ZIG_TARGET="x86_64-macos" ;;
        macos-arm64)                     ZIG_TARGET="aarch64-macos" ;;
        windows-x86_64|windows-x86_64-gnu) ZIG_TARGET="x86_64-windows-gnu" ;;
        *)
            # Fallback: maybe user passed a triple in preset field?
            ZIG_TARGET="$TARGET_PRESET"
            ;;
    esac
    log "Resolved preset '$TARGET_PRESET' to '$ZIG_TARGET'"
else
    # No target specified.
    # In v2, 'target' was required. In v3, strict_version/setup_only might check this.
    # However, for setup-only purposes or native builds, maybe we default to native?
    # For now, leave empty and let downstream fail if they need it.
    ZIG_TARGET=""
    log "No target specified. Environment variables for cross-compilation will be skipped."
fi

# 3. Project Type Resolution
if [[ "$PROJECT_TYPE" == "auto" ]]; then
    if [[ -f "Cargo.toml" ]]; then PROJECT_TYPE="rust";
    elif [[ -f "go.mod" ]]; then PROJECT_TYPE="go";
    elif [[ -f "build.zig" ]]; then PROJECT_TYPE="zig";
    else PROJECT_TYPE="c"; fi
    log "Auto-detected project_type: $PROJECT_TYPE"
fi

# 4. Environment Exports helpers
export_var() {
    local k="$1"
    local v="$2"
    echo "$k=$v" >> "$GITHUB_ENV"
    export "$k=$v"
}

# 5. Core Zig Env (only if target resolving worked)
if [[ -n "$ZIG_TARGET" ]]; then
    export_var "CC" "zig cc -target $ZIG_TARGET"
    export_var "CXX" "zig c++ -target $ZIG_TARGET"
    export_var "AR" "zig ar"
    export_var "RANLIB" "zig ranlib"
    export_var "ZIG_TARGET" "$ZIG_TARGET"
fi

# 6. Language Specifics

if [[ "$PROJECT_TYPE" == "go" && -n "$ZIG_TARGET" ]]; then
    export_var "CGO_ENABLED" "1"
    # Basic Go heuristics
    if [[ "$ZIG_TARGET" == *linux* ]]; then export_var "GOOS" "linux"; fi
    if [[ "$ZIG_TARGET" == *macos* ]]; then export_var "GOOS" "darwin"; fi
    if [[ "$ZIG_TARGET" == *windows* ]]; then export_var "GOOS" "windows"; fi

    if [[ "$ZIG_TARGET" == *x86_64* ]]; then export_var "GOARCH" "amd64"; fi
    if [[ "$ZIG_TARGET" == *aarch64* ]]; then export_var "GOARCH" "arm64"; fi
    log "Go cross-compilation enabled."

elif [[ "$PROJECT_TYPE" == "rust" && -n "$ZIG_TARGET" ]]; then
    # Rust Linker Wrapper

    # 1. Map to Rust Triple
    RUST_TRIPLE="$ZIG_TARGET"
    case "$ZIG_TARGET" in
        *macos*)
           if [[ "$ZIG_TARGET" != *apple-darwin* ]]; then
                RUST_TRIPLE="${ZIG_TARGET/macos/apple-darwin}"
           fi
           ;;
        *linux-musl*)
           if [[ "$ZIG_TARGET" != *unknown-linux-musl* ]]; then
                RUST_TRIPLE="${ZIG_TARGET/linux-musl/unknown-linux-musl}"
           fi
           ;;
        *linux-gnu*)
           if [[ "$ZIG_TARGET" != *unknown-linux-gnu* ]]; then
                RUST_TRIPLE="${ZIG_TARGET/linux-gnu/unknown-linux-gnu}"
           fi
           ;;
        *windows-gnu*)
           if [[ "$ZIG_TARGET" != *pc-windows-gnu* ]]; then
                RUST_TRIPLE="${ZIG_TARGET/windows-gnu/pc-windows-gnu}"
           fi
           ;;
    esac

    # 2. Generate Wrapper
    SANITIZED_TRIPLE=$(echo "$RUST_TRIPLE" | tr '-' '_')
    LINKER_VAR="CARGO_TARGET_$(echo "$SANITIZED_TRIPLE" | tr '[:lower:]' '[:upper:]')_LINKER"

    WRAPPER_DIR="${RUNNER_TEMP:-/tmp}/zig-wrappers"
    mkdir -p "$WRAPPER_DIR"
    WRAPPER="$WRAPPER_DIR/cc-$ZIG_TARGET.sh"

    echo '#!/bin/sh' > "$WRAPPER"
    echo "exec zig cc -target $ZIG_TARGET \"\$@\"" >> "$WRAPPER"
    chmod +x "$WRAPPER"

    export_var "$LINKER_VAR" "$WRAPPER"
    export_var "CC_${SANITIZED_TRIPLE}" "zig cc -target $ZIG_TARGET"
    export_var "CXX_${SANITIZED_TRIPLE}" "zig c++ -target $ZIG_TARGET"

    log "Rust linker set: $LINKER_VAR -> $WRAPPER"
fi

# 7. Outputs
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "zig_target_triple=${ZIG_TARGET:-}" >> "$GITHUB_OUTPUT"
fi
