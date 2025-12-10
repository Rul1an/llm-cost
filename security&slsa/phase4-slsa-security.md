# Phase 4: SLSA Security & Supply Chain

**Status:** PLANNED  
**Effort:** 2-3 days  
**Dependencies:** Phase 3 Complete (Golden Tests ✅)

---

## 1. Executive Summary

This phase implements **SLSA Build Level 2** compliance for llm-cost releases, providing cryptographic proof of build provenance and artifact integrity.

### What Users Get

```bash
# Download release
curl -LO https://github.com/Rul1an/llm-cost/releases/download/v1.0.0/llm-cost-linux-x86_64

# Verify it came from our CI (not tampered)
gh attestation verify llm-cost-linux-x86_64 --repo Rul1an/llm-cost

# Check software bill of materials
cat llm-cost-linux-x86_64.cdx.json | jq '.components'

# Verify signature
cosign verify-blob \
  --signature llm-cost-linux-x86_64.sig \
  --certificate llm-cost-linux-x86_64.crt \
  --certificate-identity-regexp "https://github.com/Rul1an/llm-cost" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  llm-cost-linux-x86_64
```

---

## 2. SLSA Framework Overview

### 2.1 What is SLSA?

**Supply-chain Levels for Software Artifacts (SLSA)** is a security framework that:
- Defines levels of supply chain security (L1 → L4)
- Specifies provenance requirements
- Enables automated verification

### 2.2 SLSA Levels

| Level | Name | Requirements |
|-------|------|--------------|
| **L1** | Build Provenance | Provenance exists (unsigned) |
| **L2** | Signed Provenance | Provenance is signed, tamper-evident |
| **L3** | Hardened Builds | Isolated build environment, non-forgeable |
| **L4** | Hermetic Builds | Reproducible, all dependencies pinned |

### 2.3 Our Target: Level 2

**Why Level 2?**

| Level | Complexity | Value | Decision |
|-------|-----------|-------|----------|
| L1 | Low | Basic | Too weak |
| **L2** | Medium | **Strong** | ✅ **Target** |
| L3 | High | Very Strong | Future (requires reusable workflows) |
| L4 | Very High | Maximum | Overkill for CLI tool |

**Level 2 Requirements:**
- [x] Provenance generated during build
- [x] Provenance is signed
- [x] Signature uses OIDC (keyless)
- [x] Consumers can verify

---

## 3. Architecture

### 3.1 Security Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                     GitHub Actions CI                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐         │
│  │   Build     │───▶│   SBOM      │───▶│   Sign      │         │
│  │  (zig build)│    │   (Syft)    │    │  (Cosign)   │         │
│  └─────────────┘    └─────────────┘    └─────────────┘         │
│         │                  │                  │                 │
│         ▼                  ▼                  ▼                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐         │
│  │ llm-cost    │    │ .cdx.json   │    │ .sig + .crt │         │
│  │  (binary)   │    │  (SBOM)     │    │ (signature) │         │
│  └─────────────┘    └─────────────┘    └─────────────┘         │
│         │                  │                  │                 │
│         └──────────────────┼──────────────────┘                 │
│                            ▼                                    │
│                   ┌─────────────────┐                           │
│                   │  GitHub         │                           │
│                   │  Attestation    │                           │
│                   │  (Provenance)   │                           │
│                   └─────────────────┘                           │
│                            │                                    │
└────────────────────────────┼────────────────────────────────────┘
                             ▼
                   ┌─────────────────┐
                   │  GitHub Release │
                   │  (All Artifacts)│
                   └─────────────────┘
```

### 3.2 Artifact Matrix

| Artifact | Format | Purpose |
|----------|--------|---------|
| `llm-cost-linux-x86_64` | ELF binary | Main executable |
| `llm-cost-linux-x86_64.cdx.json` | CycloneDX JSON | Software Bill of Materials |
| `llm-cost-linux-x86_64.sig` | Base64 | Cosign signature |
| `llm-cost-linux-x86_64.crt` | PEM | Signing certificate |
| `llm-cost-linux-x86_64.intoto.jsonl` | SLSA Provenance | Build attestation |

---

## 4. Implementation

### 4.1 Release Workflow

```yaml
# .github/workflows/release.yml
name: Release

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: write      # Create releases
  id-token: write      # OIDC for keyless signing
  attestations: write  # GitHub Attestations

env:
  ZIG_VERSION: "0.14.0"

jobs:
  # ============================================================
  # Job 1: Build Matrix
  # ============================================================
  build:
    name: Build (${{ matrix.target }})
    runs-on: ${{ matrix.os }}
    
    strategy:
      fail-fast: false
      matrix:
        include:
          - os: ubuntu-latest
            target: x86_64-linux-musl
            artifact: llm-cost-linux-x86_64
            binary: llm-cost
          - os: ubuntu-latest
            target: aarch64-linux-musl
            artifact: llm-cost-linux-arm64
            binary: llm-cost
          - os: ubuntu-latest
            target: x86_64-windows-gnu
            artifact: llm-cost-windows-x86_64.exe
            binary: llm-cost.exe
          - os: macos-latest
            target: aarch64-macos
            artifact: llm-cost-macos-arm64
            binary: llm-cost
          - os: macos-latest
            target: x86_64-macos
            artifact: llm-cost-macos-x86_64
            binary: llm-cost

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Zig
        uses: Rul1an/zig-cross-compile-action@v3
        with:
          version: ${{ env.ZIG_VERSION }}
          target: ${{ matrix.target }}
          setup_only: true

      - name: Build
        run: |
          zig build -Doptimize=ReleaseFast -Dtarget=${{ matrix.target }}
          mkdir -p dist
          cp "zig-out/bin/${{ matrix.binary }}" "dist/${{ matrix.artifact }}"

      - name: Upload Build Artifact
        uses: actions/upload-artifact@v4
        with:
          name: ${{ matrix.artifact }}
          path: dist/${{ matrix.artifact }}
          if-no-files-found: error

  # ============================================================
  # Job 2: Generate SBOM (Linux only - Syft requirement)
  # ============================================================
  sbom:
    name: Generate SBOM
    needs: build
    runs-on: ubuntu-latest
    
    strategy:
      matrix:
        artifact:
          - llm-cost-linux-x86_64
          - llm-cost-linux-arm64
          - llm-cost-windows-x86_64.exe

    steps:
      - name: Download Artifact
        uses: actions/download-artifact@v4
        with:
          name: ${{ matrix.artifact }}
          path: dist/

      - name: Install Syft
        uses: anchore/sbom-action/download-syft@v0

      - name: Generate SBOM
        run: |
          syft scan "file:dist/${{ matrix.artifact }}" \
            -o cyclonedx-json \
            > "dist/${{ matrix.artifact }}.cdx.json"

      - name: Upload SBOM
        uses: actions/upload-artifact@v4
        with:
          name: ${{ matrix.artifact }}-sbom
          path: dist/${{ matrix.artifact }}.cdx.json

  # ============================================================
  # Job 3: Sign Artifacts (Keyless via OIDC)
  # ============================================================
  sign:
    name: Sign Artifacts
    needs: build
    runs-on: ubuntu-latest
    
    strategy:
      matrix:
        artifact:
          - llm-cost-linux-x86_64
          - llm-cost-linux-arm64
          - llm-cost-windows-x86_64.exe

    steps:
      - name: Download Artifact
        uses: actions/download-artifact@v4
        with:
          name: ${{ matrix.artifact }}
          path: dist/

      - name: Install Cosign
        uses: sigstore/cosign-installer@v3

      - name: Sign with Cosign (Keyless)
        env:
          COSIGN_EXPERIMENTAL: "1"
        run: |
          cosign sign-blob \
            --yes \
            --output-signature "dist/${{ matrix.artifact }}.sig" \
            --output-certificate "dist/${{ matrix.artifact }}.crt" \
            "dist/${{ matrix.artifact }}"

      - name: Upload Signature
        uses: actions/upload-artifact@v4
        with:
          name: ${{ matrix.artifact }}-sig
          path: |
            dist/${{ matrix.artifact }}.sig
            dist/${{ matrix.artifact }}.crt

  # ============================================================
  # Job 4: Generate Provenance Attestation
  # ============================================================
  provenance:
    name: Generate Provenance
    needs: build
    runs-on: ubuntu-latest
    
    strategy:
      matrix:
        artifact:
          - llm-cost-linux-x86_64
          - llm-cost-linux-arm64
          - llm-cost-windows-x86_64.exe

    steps:
      - name: Download Artifact
        uses: actions/download-artifact@v4
        with:
          name: ${{ matrix.artifact }}
          path: dist/

      - name: Generate Attestation
        uses: actions/attest-build-provenance@v2
        with:
          subject-path: dist/${{ matrix.artifact }}

  # ============================================================
  # Job 5: Create Release
  # ============================================================
  release:
    name: Create Release
    needs: [build, sbom, sign, provenance]
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Download All Artifacts
        uses: actions/download-artifact@v4
        with:
          path: artifacts/

      - name: Prepare Release Assets
        run: |
          mkdir -p release
          
          # Binaries
          cp artifacts/llm-cost-linux-x86_64/llm-cost-linux-x86_64 release/
          cp artifacts/llm-cost-linux-arm64/llm-cost-linux-arm64 release/
          cp artifacts/llm-cost-windows-x86_64.exe/llm-cost-windows-x86_64.exe release/
          cp artifacts/llm-cost-macos-arm64/llm-cost-macos-arm64 release/
          cp artifacts/llm-cost-macos-x86_64/llm-cost-macos-x86_64 release/
          
          # SBOMs
          cp artifacts/llm-cost-linux-x86_64-sbom/*.cdx.json release/
          cp artifacts/llm-cost-linux-arm64-sbom/*.cdx.json release/
          cp artifacts/llm-cost-windows-x86_64.exe-sbom/*.cdx.json release/
          
          # Signatures
          cp artifacts/llm-cost-linux-x86_64-sig/*.sig release/
          cp artifacts/llm-cost-linux-x86_64-sig/*.crt release/
          cp artifacts/llm-cost-linux-arm64-sig/*.sig release/
          cp artifacts/llm-cost-linux-arm64-sig/*.crt release/
          cp artifacts/llm-cost-windows-x86_64.exe-sig/*.sig release/
          cp artifacts/llm-cost-windows-x86_64.exe-sig/*.crt release/
          
          # Checksums
          cd release
          sha256sum * > SHA256SUMS.txt

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          files: release/*
          generate_release_notes: true
          body: |
            ## Verification
            
            All artifacts are signed and include SLSA Build Level 2 provenance.
            
            ### Verify with GitHub CLI
            ```bash
            gh attestation verify llm-cost-linux-x86_64 --repo Rul1an/llm-cost
            ```
            
            ### Verify with Cosign
            ```bash
            cosign verify-blob \
              --signature llm-cost-linux-x86_64.sig \
              --certificate llm-cost-linux-x86_64.crt \
              --certificate-identity-regexp "https://github.com/Rul1an/llm-cost" \
              --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
              llm-cost-linux-x86_64
            ```
            
            ### SBOM
            Each binary has a CycloneDX SBOM (`.cdx.json`) for dependency transparency.
```

### 4.2 SBOM Format (CycloneDX)

```json
{
  "$schema": "http://cyclonedx.org/schema/bom-1.5.schema.json",
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "version": 1,
  "metadata": {
    "timestamp": "2025-12-10T12:00:00Z",
    "tools": [
      {
        "vendor": "anchore",
        "name": "syft",
        "version": "1.18.0"
      }
    ],
    "component": {
      "type": "application",
      "name": "llm-cost",
      "version": "1.0.0"
    }
  },
  "components": [
    {
      "type": "library",
      "name": "zig-std",
      "version": "0.14.0",
      "purl": "pkg:generic/zig-std@0.14.0"
    }
  ]
}
```

### 4.3 Provenance Format (SLSA)

```json
{
  "_type": "https://in-toto.io/Statement/v1",
  "subject": [
    {
      "name": "llm-cost-linux-x86_64",
      "digest": {
        "sha256": "abc123..."
      }
    }
  ],
  "predicateType": "https://slsa.dev/provenance/v1",
  "predicate": {
    "buildDefinition": {
      "buildType": "https://actions.github.io/buildtypes/workflow/v1",
      "externalParameters": {
        "workflow": {
          "ref": "refs/tags/v1.0.0",
          "repository": "https://github.com/Rul1an/llm-cost",
          "path": ".github/workflows/release.yml"
        }
      }
    },
    "runDetails": {
      "builder": {
        "id": "https://github.com/actions/runner"
      },
      "metadata": {
        "invocationId": "https://github.com/Rul1an/llm-cost/actions/runs/12345"
      }
    }
  }
}
```

---

## 5. Integration with zig-cross-compile-action

Your action already supports SBOM and signing. Here's the streamlined approach:

### 5.1 Using Action's Built-in Features

```yaml
- name: Build + Sign + SBOM
  uses: Rul1an/zig-cross-compile-action@v3
  with:
    version: "0.14.0"
    target: ${{ matrix.target }}
    project-type: zig
    cmd: "-Doptimize=ReleaseFast"
    
    # Supply Chain Security
    sbom: true
    sbom_target: "zig-out/bin/${{ matrix.binary }}"
    sbom_output: "dist/${{ matrix.artifact }}.cdx.json"
    
    sign: true
    sign_artifact: "zig-out/bin/${{ matrix.binary }}"
```

### 5.2 Action Enhancement Suggestions

| Current | Enhancement |
|---------|-------------|
| Syft scan | Add `--catalogers=binary` for better binary analysis |
| Cosign output | Support custom output paths for `.sig`/`.crt` |
| Provenance | Integrate `actions/attest-build-provenance` |

---

## 6. Verification Guide

### 6.1 For End Users

```bash
# Option 1: GitHub CLI (Easiest)
gh attestation verify llm-cost-linux-x86_64 --repo Rul1an/llm-cost

# Option 2: Cosign (More control)
cosign verify-blob \
  --signature llm-cost-linux-x86_64.sig \
  --certificate llm-cost-linux-x86_64.crt \
  --certificate-identity-regexp "https://github.com/Rul1an/llm-cost" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  llm-cost-linux-x86_64

# Option 3: SLSA Verifier (Strict)
slsa-verifier verify-artifact llm-cost-linux-x86_64 \
  --provenance-path llm-cost-linux-x86_64.intoto.jsonl \
  --source-uri github.com/Rul1an/llm-cost \
  --source-tag v1.0.0
```

### 6.2 Verification Output

```
✓ Verification succeeded!

sha256:abc123... was attested by:
REPO                  PREDICATE_TYPE                    WORKFLOW
Rul1an/llm-cost       https://slsa.dev/provenance/v1    .github/workflows/release.yml@refs/tags/v1.0.0
```

---

## 7. Security Properties

### 7.1 What Level 2 Protects Against

| Attack | Protected? | How |
|--------|-----------|-----|
| Binary tampering after build | ✅ Yes | Signature verification fails |
| Malicious CI modification | ⚠️ Partial | Provenance shows build source |
| Dependency confusion | ✅ Yes | SBOM lists exact components |
| Compromised developer machine | ✅ Yes | Build happens in CI, not locally |
| Man-in-the-middle on download | ✅ Yes | Signature verification |

### 7.2 What It Does NOT Protect Against

| Attack | Why Not |
|--------|---------|
| Malicious source code | Provenance ≠ code review |
| Compromised CI secrets | Need Level 3 (isolated builds) |
| Supply chain attacks on Zig itself | Out of scope |

---

## 8. Release Checklist

### Before Release

- [ ] All tests passing (unit, golden, parity)
- [ ] Version bumped in `src/main.zig`
- [ ] CHANGELOG updated
- [ ] Tag created: `git tag -s v1.0.0 -m "Release v1.0.0"`

### Release Verification

- [ ] All matrix builds succeeded
- [ ] SBOMs generated for Linux/Windows binaries
- [ ] Signatures generated for Linux/Windows binaries
- [ ] GitHub Attestations visible in UI
- [ ] SHA256SUMS.txt matches actual checksums

### Post-Release

- [ ] Verify download: `gh attestation verify <artifact>`
- [ ] Test binary on each platform
- [ ] Update documentation with verification instructions

---

## 9. File Structure

```
llm-cost/
├── .github/
│   └── workflows/
│       ├── ci.yml           # PR checks
│       ├── golden.yml       # Parity tests
│       └── release.yml      # SLSA release ← NEW
├── docs/
│   ├── VERIFICATION.md      # User verification guide ← NEW
│   └── SECURITY.md          # Security policy ← NEW
└── scripts/
    └── verify-release.sh    # Local verification script ← NEW
```

---

## 10. Timeline

| Day | Task |
|-----|------|
| 1 | Implement release.yml workflow |
| 1 | Test SBOM generation locally |
| 2 | Test signing with Cosign |
| 2 | Test GitHub Attestations |
| 3 | Create verification documentation |
| 3 | Dry-run release (v0.9.0-rc1) |

---

## 11. Success Criteria

| Criterion | Verification |
|-----------|--------------|
| SBOM exists | `.cdx.json` in release assets |
| Signature valid | `cosign verify-blob` passes |
| Attestation exists | `gh attestation verify` passes |
| Checksums match | `sha256sum -c SHA256SUMS.txt` |
| SLSA Level 2 | All Level 2 requirements met |

---

## 12. Future: Path to Level 3

For SLSA Level 3, we would need:

1. **Reusable Workflow** - Move build logic to shared workflow
2. **Isolated Builder** - Use `slsa-framework/slsa-github-generator`
3. **Non-forgeable Provenance** - Signing happens outside user control

```yaml
# Future Level 3 approach
jobs:
  build:
    uses: slsa-framework/slsa-github-generator/.github/workflows/builder_go_slsa3.yml@v1.9.0
    # Note: No native Zig builder exists yet - would need BYOB framework
```

**Recommendation:** Level 2 is sufficient for v1.0. Consider Level 3 for v2.0 if enterprise adoption requires it.
