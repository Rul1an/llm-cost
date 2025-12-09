# Security Policy

This document describes how security is handled for `llm-cost`:
a cross-platform CLI for offline token counting, pricing, and JSONL pipelines.

---

## Supported Versions

`llm-cost` follows semantic versioning (`vMAJOR.MINOR.PATCH`).

We generally support:

- The **latest released minor** on the **latest major** `vX.Y.Z`.
- Any version explicitly marked as **LTS** in the README or Releases page.

Older versions may receive security fixes on a best-effort basis only.
For production use, we strongly recommend staying on the latest minor release.

---

## Reporting a Vulnerability

If you believe you have found a security issue in `llm-cost` (e.g. RCE,
path traversal, malicious input processing, or supply-chain issues):

1. **Do not** open a public GitHub Issue with details.
2. Instead, use **one** of the following channels:

   - **GitHub Security Advisory**:
     Open a private report via the “Report a vulnerability” button on the repo’s
     Security tab, if enabled.

   - **Email (preferred fallback)**:
     Send a report to:

     > `security@your-domain.example`  <!-- TODO: replace with real address -->

     Please include:
     - Steps to reproduce
     - A minimal proof-of-concept if possible
     - A short impact description (what an attacker can gain)
     - Any affected version(s) and platform(s)

3. You should receive an acknowledgement within **5 business days**.

If you have not heard back within 7 days, you may optionally:

- Re-send your message, and
- Mention the delay (in case of spam filtering or routing issues).

---

## Vulnerability Handling Process

Once a report is received, we will aim to:

1. **Triage** within 5 business days:
   - Confirm whether the issue is reproducible
   - Classify severity (low / medium / high / critical)
2. **Mitigate**:
   - Prepare a fix on a private branch where applicable
   - Add or update regression tests (e.g. golden tests, fuzz harnesses)
3. **Release**:
   - Publish a patched version (e.g. `vX.Y.Z+1`)
   - Update release notes with a short, **non-sensitive** security entry
4. **Coordinate disclosure**:
   - Coordinate an agreed disclosure time frame with the reporter,
     especially for high-impact vulnerabilities.

We are happy to credit reporters in release notes if they wish, unless they
request anonymity.

---

## Dependencies & Supply Chain

`llm-cost` is written in Zig and aims to minimize runtime dependencies:

- The CLI builds to a **single static binary** per platform.
- There is no embedded JavaScript, Python, or dynamic plugin system.
- Tokenization and pricing rely on **embedded data files**
  (e.g. default pricing JSON) and compiled-in tokenization tables.

### Build & CI

All builds are performed via:

- `zig build` / `zig build test` / `zig build test-golden`
- GitHub Actions workflows:
  - `.github/workflows/ci.yml`
  - `.github/workflows/release.yml`
  - `.github/workflows/fuzz.yml`

To reduce supply-chain risk:

- GitHub Actions are **pinned by SHA**, not by floating tags, for example:
  - `actions/checkout@692973e3d9...`
  - `actions/upload-artifact@654d0383cd...`
  - `actions/download-artifact@65a9edc588...`
- Cross-compilation and signing use a pinned `Rul1an/zig-cross-compile-action`
  commit:
  - `Rul1an/zig-cross-compile-action@66076af8e44f186b08e2d05b5a1aa7c91c8042d6`

This means a third-party cannot silently pull in a different version of these
actions without a commit changing the workflow.

---

## Release Integrity, SBOM & Provenance

Release binaries are built by the **Release** workflow (`release.yml`) with
the following guarantees:

- **Reproducible build configuration**:
  - Zig version is fixed to `0.13.0` via `mlugg/setup-zig@v1`.
  - `zig build` is run with `-Doptimize=ReleaseFast` for release artifacts.
- **Pre-release verification** (`verify` job):
  - `zig build test` (unit tests)
  - `zig build test-golden` (CLI contract / golden tests)
  - `zig build fuzz` (fuzz harness sanity)
  - `zig build test-parity` (tokenization parity vs reference corpus)
  - `zig build bench-bpe` (BPE microbenchmark smoke test)

### SBOM (Software Bill of Materials)

For supported targets (Linux, Windows), the release workflow generates a
CycloneDX JSON SBOM via the cross-compile action:

- SBOM files are produced as:
  - `dist/llm-cost-<platform>.cdx.json`

These SBOMs describe:

- The build artifact (`llm-cost-<platform>`)
- Its immediate library dependencies (if any)
- Basic environment metadata

Consumers can use SBOM tools (e.g. `cyclonedx-cli`) to inspect or integrate
this into their own SBOM pipelines.

### Signing & Verification

For non-macOS targets, binaries are cryptographically signed during the
`build-matrix` job:

- Signatures and certificates are emitted alongside the binary, e.g.:
  - `dist/llm-cost-<platform>`
  - `dist/llm-cost-<platform>.sig`
  - `dist/llm-cost-<platform>.crt`

The signing uses **keyless signing** via GitHub OIDC (Sigstore-style)
through the pinned `Rul1an/zig-cross-compile-action`:

- This allows downstream consumers to verify:
  - The artifact was produced by the GitHub Actions workflow for this repo.
  - The build used the pinned commit and workflow configuration.

> **Note:** We do not currently claim strict compliance with a specific
> SLSA level. However, the combination of:
> - Pinned GitHub Actions by SHA
> - SBOM generation
> - Keyless signing with OIDC
> - Pre-release tests (unit, fuzz, golden, parity)
>
> Provides a strong baseline of supply-chain and provenance guarantees for
> a CLI binary.

---

## Fuzzing, Parity & Golden Tests

To catch bugs and edge cases in tokenization and pricing:

- **Fuzzing**:
  - `zig build fuzz` exercises the tokenizer with random and adversarial inputs.
  - The fuzz harness is updated to use the latest `engine.estimateTokens`
    API (including strict/ordinary modes).

- **Parity tests**:
  - `zig build test-parity` compares tokenization results against a curated
    “evil corpus” (e.g. `testdata/evil_corpus_v2.jsonl`) to maintain parity
    with reference tokenizers (like OpenAI’s tiktoken).

- **Golden CLI contract tests**:
  - `zig build test-golden` runs end-to-end CLI tests against “golden” files:
    - `tokens/hello`
    - `tokens/bad_model`
    - `price/simple_price`
    - `pipe/one_line`
    - `pipe/partial_fail`
  - These tests assert:
    - **STDOUT EXACT** (JSON contract)
    - **STDERR EXACT** (error/summary contract)
    - **Exit code EXACT** (BSD `sysexits` semantics)

Examples:

- `llm-cost tokens --model gpt-4o ...` → exit `0` on success
- `llm-cost tokens --model foo/bar ...` → exit `65` (`EX_DATAERR`) with
  a clear error message
- Quota errors in `pipe` mode (`--max-tokens`, `--max-cost`) map to
  `EX_USAGE` (`64`), not a crash.

---

## Hardening Commitments

Going forward, we intend to:

- Keep **GitHub Actions pinned** to specific SHAs.
- Require **passing golden tests** for any CLI contract change.
- Treat tokenizer/parity regressions as release-blocking issues.
- Evolve our BPE engine (BPE v2 → v3) without breaking compatibility with
  upstream tokenizers unless explicitly versioned as such.

If your use case requires additional assurances (e.g. internal attestation,
custom SBOM format, or specific SLSA level), please open a discussion or
contact us privately.
