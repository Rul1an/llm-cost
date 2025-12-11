# Security Architecture & Supply Chain

This document provides a deeper view of llm-cost's security and supply chain
story: threat model, build pipeline, verification, and hardening measures.

---

## 1. Overview

llm-cost is an **offline** token counting & pricing CLI. It is intended to be:

- Safe to run in CI/CD pipelines
- Safe to run on sensitive JSONL data
- Predictable and machine-friendly, with stable JSON contracts

This is primarily an **offline** tool: it does not contact model vendors for validation.
However, v0.9.0+ introduces an optional `update-db` command to securely fetch pricing updates from the official registry. This is user-initiated and cryptographically verified.

---

## 2. Threat Model

### 2.1 What we protect against

- **Malicious or malformed input data**
  - Extremely long lines
  - Invalid JSON
  - Non-UTF-8 or mixed encodings
- **Denial of service via resource exhaustion**
  - Unbounded memory usage
  - Unbounded token counting
- **Supply chain attacks**
  - Compromised GitHub Actions workflow versions
  - Tampering with release artifacts between CI and end user

### 2.2 What we do *not* (fully) protect against

- Host-level compromises (if your machine is compromised, llm-cost cannot help)
- Attackers who can modify:
  - The source repository you build from
  - The Zig compiler/toolchain you use
- Non-CLI integrations that bypass our CLI contract (e.g. embedding parts of
  the library without the same checks)

---

## 3. Build & Supply Chain Hardening

### 3.1 Zig Toolchain

- Build is pinned to **Zig 0.13.x**:
  `build.zig` explicitly errors out on other major/minor versions.
- CI uses `mlugg/setup-zig@v1` with a pinned version (`0.13.0`) to ensure
  reproducible builds.

### 3.2 CI Workflows

We use three main workflows:

#### `ci.yml`

- Runs on `push` and `pull_request`.
- Steps:
  - `zig build`
  - `zig build test`
  - `zig build test-golden`
- Actions are pinned by SHA (e.g. `actions/checkout@…`, `mlugg/setup-zig@…`).

#### `fuzz.yml`

- Runs fuzz tests (`zig build fuzz`) with the current fuzz harness.
- Uses the same pinned action pattern.

#### `release.yml`

- Triggers on tags `v*`.
- Jobs:
  1. **verify**
     - `zig build test`
     - `zig build test-golden`
     - `zig build fuzz`
     - `zig build test-parity`
     - `zig build bench-bpe` (sanity only)
  2. **build-matrix**
     - Cross-compiles for Linux/macOS/Windows targets using
       `Rul1an/zig-cross-compile-action@<pinned SHA>`.
     - Produces:
       - Platform-specific binaries
       - CycloneDX SBOMs (`*.cdx.json`)
       - Signatures and certificates (`.sig`, `.crt`) for supported targets
     - Artifacts uploaded via `actions/upload-artifact@<pinned SHA>`.
  3. **release**
     - Downloads artifacts and publishes a GitHub Release using
       `softprops/action-gh-release@<pinned SHA>`.

All GitHub Actions are **pinned by SHA**, not floating tags, to reduce the risk
of upstream supply chain compromise.

### 3.3 SBOM & Signing

For supported targets (Linux, Windows):

- A **CycloneDX SBOM** is generated for each binary:
  - `dist/llm-cost-<suffix>.cdx.json`
- Binaries are **signed** by the CI workflow:
  - `dist/llm-cost-<suffix>` – the binary
  - `dist/llm-cost-<suffix>.sig` – signature
  - `dist/llm-cost-<suffix>.crt` – certificate/attestation

These artifacts are published in the GitHub Release alongside the binaries.

### 3.4 SLSA Level 2 Compliance

> **Note:** SLSA Level 2 applies to releases ≥ v0.4.0. Older versions may not have provenance.

llm-cost release artifacts meet **SLSA Build Level 2** requirements:

| Requirement | How We Meet It |
|-------------|----------------|
| Version controlled | Git repository, tagged releases |
| Scripted build | `build.zig` defines all build steps |
| Build service | GitHub Actions (hosted runners) |
| Provenance | Generated via workflow, attached to release |
| Isolated | Each build runs in fresh VM |

**Verification:** See section 6 for how to verify provenance.

---

## 4. Runtime Security & Hardening

### 4.1 Offline Operation

llm-cost:

- Does **not** perform HTTP or other network calls.
- Reads only from:
  - `stdin`
  - Path arguments passed on the command line
- Writes only to:
  - `stdout` for primary output
  - `stderr` for diagnostics / summaries

This makes it suitable for:

- Air-gapped environments
- Minimal containers
- Locked-down CI runners

### 4.2 Input Validation

#### Tokens / Price commands

- `tokens` and `price` commands:
  - Read full input into memory (bounded by Zig's allocator and OS).
  - Use explicit UTF-8 aware tokenization (or vendor-specific encodings).
- Unknown models:
  - `price` requires a known model in the pricing database and exits with a
    non-zero status if not found.
  - `tokens` enforces an error for `--model` with an unknown name in the CLI
    contract.

#### Pipe command

- `pipe` processes **JSONL** (one JSON object per line).
- Protections:
  - **Max line size** (default 10 MB, configurable in code via `max_line_bytes`).
  - Strict JSON parsing:
    - Invalid JSON → error recorded per line.
    - Missing or non-string `--field` → error recorded per line.
  - Per-line error handling:
    - `--fail-on-error` → abort the stream on first failure.
    - Otherwise, line is skipped and counted as `failed`.

### 4.3 Quotas & Resource Limits

`pipe` supports hard quotas to prevent unbounded processing:

#### `--max-tokens <N>`

- Enforced **across the entire stream**.
- Includes both input and (when `--mode price`) output tokens.
- When exceeded:
  - Summary is printed (if `--summary` enabled).
  - The command terminates with exit code `64` (quota exceeded).

#### `--max-cost <USD>`

- Enforced on the **accumulated cost**.
- Same behavior as `--max-tokens` on breach.

By design, quotas force **single-threaded mode** to ensure deterministic
enforcement. In multi-threaded mode (`--workers > 1` without quotas), quotas
are disabled.

### 4.4 Exit Codes

llm-cost uses BSD sysexits-compatible exit codes:

| Code | Meaning | Example |
|------|---------|---------|
| 0 | Success | Normal completion |
| 1 | Generic error | Internal error |
| 2 | Usage error | Invalid arguments |
| 64 | Quota exceeded | `--max-tokens` breached |
| 65 | Partial failure | Some lines failed in pipe |

This enables reliable error handling in scripts and CI pipelines.

### 4.5 Logging & Quiet Mode

- Errors per line are logged to `stderr` with:
  - Line number
  - Short message
  - Optional Zig error name
- `--quiet` suppresses per-line diagnostics, which is useful for:
  - CI pipelines where JSON output is the only desired output
  - Tools that parse `stderr` separately

A summary line (or JSON summary) can be produced via `--summary` and
`--summary-format`.

### 4.6 Secure Updates (Client Side)

The `update-db` command fetches pricing data from `https://prices.llm-cost.dev/`.
This process is secured via **Ed25519 Minisign Verification**:

1.  **Fetch**: Downloads `pricing_db.json` and `pricing_db.json.minisig`.
2.  **Verify**: The `.minisig` is verified against the **embedded public key** (hardcoded in the binary).
    - If verification fails, the update is aborted.
    - If the timestamp is too old (replay attack), the update is aborted.
3.  **Atomic Swap**: Data is written to a temporary file and atomically renamed only after successful verification.

This ensures that even if the pricing server or CDN is compromised, clients will not accept malicious pricing data.

---

## 5. Testing & Fuzzing

### 5.1 Unit Tests

```bash
zig build test
```

Covers:
- Core tokenization logic
- Pricing calculations
- Model registry resolution (including vendor prefixes and aliases)

### 5.2 Golden CLI Tests

```bash
zig build test-golden
```

Runs the compiled `llm-cost` binary end-to-end against **golden fixtures**:
- `tokens/hello`
- `tokens/bad_model` (ensures correct error handling & exit codes)
- `price/simple_price`
- `pipe/one_line`
- `pipe/partial_fail`

Each case checks:
- `stdout` (JSON/NDJSON contract)
- `stderr` (diagnostics or summary)
- **Exit code** (BSD sysexits mapping)

This enforces the CLI "contract" to remain stable across releases.

### 5.3 Fuzz Tests

```bash
zig build fuzz
```

Fuzzes:
- Tokenization pipelines
- JSON parsing and `pipe` processing

Aims to detect:
- Crashes
- Panics
- Assertion failures
- Unexpected UB in the tokenizer engine

### 5.4 Parity Tests

```bash
zig build test-parity
```

Compares llm-cost's tokenization against an "evil corpus" and/or external
reference tokenizers (where applicable) to maintain parity guarantees with
tiktoken.

---

## 6. Verifying Releases

This section describes how to verify a downloaded release artifact.

> Note: Names and exact commands may evolve; always check the latest GitHub
> Release page for actual filenames.

### 6.1 Download Artifacts

From the GitHub Release page, download:

- `llm-cost-<suffix>` – executable
- `llm-cost-<suffix>.sig` – signature
- `llm-cost-<suffix>.crt` – certificate/attestation
- `llm-cost-<suffix>.cdx.json` – CycloneDX SBOM

Place them in the same directory.

### 6.2 Verify Checksum

Each release includes a `checksums.txt` file with SHA256 hashes:

```bash
# Download checksums
curl -LO https://github.com/Rul1an/llm-cost/releases/download/v0.4.0/checksums.txt

# Verify
sha256sum -c checksums.txt
```

### 6.3 Verify Signature (example)

Depending on your environment, you may use tools like:

- `cosign` (from sigstore)
- Distribution-specific signature verification tools

Because signing is performed in GitHub-hosted CI with an OIDC identity, you
can:

1. Verify that the signature is valid for the binary.
2. Verify that the certificate/attestation chains back to GitHub and the
   expected repository (`Rul1an/REPO`) and ref (tag).

Example with cosign (if keyless signing is used):

```bash
cosign verify-blob \
  --certificate llm-cost-linux-x86_64.crt \
  --signature llm-cost-linux-x86_64.sig \
  --certificate-identity-regexp "https://github.com/Rul1an/llm-cost/.*" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  llm-cost-linux-x86_64
```

Please refer to the release notes or project README for the currently
recommended verification command, as this may evolve with signing tooling.

### 6.4 Verify SLSA Provenance

If SLSA provenance attestations are attached:

```bash
slsa-verifier verify-artifact \
  --provenance-path llm-cost-linux-x86_64.intoto.jsonl \
  --source-uri github.com/Rul1an/llm-cost \
  --source-tag v0.4.0 \
  llm-cost-linux-x86_64
```

### 6.5 Inspect SBOM

The `*.cdx.json` file is a CycloneDX SBOM that can be inspected with:

- CycloneDX tooling (`cyclonedx-cli`)
- Dependency and license scanners
- Internal compliance tools

This allows you to:

- See transitive dependencies
- Verify that there are no unexpected libraries or dynamic links
- Feed llm-cost into your organization's SBOM/asset management systems

Example:

```bash
# Install cyclonedx-cli
npm install -g @cyclonedx/cyclonedx-cli

# Validate SBOM
cyclonedx validate --input-file llm-cost-linux-x86_64.cdx.json

# View components
cyclonedx convert --input-file llm-cost-linux-x86_64.cdx.json --output-format json | jq '.components'
```

---

## 7. Security Policy Summary

| Aspect | Policy |
|--------|--------|
| **Supported Versions** | Latest minor release actively supported |
| **Reporting** | GitHub Security Advisories (preferred) |
| **Response Time** | 72h acknowledgment, 90d fix target |
| **Supply Chain** | SHA-pinned actions, pinned Zig, CI-built releases |
| **Signing** | SBOM + signatures per artifact |
| **SLSA Level** | Level 2 |
| **Runtime** | Offline only, strong input validation, quotas |
| **Testing** | Unit, golden, fuzz, parity tests |

---

## 8. Security Contacts

- **Primary:** GitHub Security Advisories (repository → Security → Advisories)
- **Backup:** See repository description for alternative contact

If you have questions about how to integrate llm-cost into a high-security
environment (air-gapped, internal registries, etc.), please open a **doc**
issue (not a security advisory) so we can extend this document accordingly.

---

## 9. Changelog

| Date | Change |
|------|--------|
| 2025-01 | Initial security documentation for Phase 1.5 |
