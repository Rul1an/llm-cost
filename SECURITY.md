# Security Policy

This document describes how we handle security for **llm-cost**, including
supported versions and how to responsibly report vulnerabilities.

---

## Supported Versions

llm-cost follows a "latest minor" support policy: only the most recent stable
release line receives regular fixes. Older versions may receive **critical**
security fixes on a best-effort basis.

| Version  | Supported | Notes                        |
|----------|-----------|-----------------------------|
| 0.7.x    | ✅         | Actively supported          |
| 0.6.x    | ⚠️         | Critical fixes only         |
| < 0.6.0  | ❌         | No longer supported         |

When in doubt, upgrade to the latest released version before filing a report.

---

## Reporting a Vulnerability


Please report vulnerabilities via email to `info@logvault.eu`.

We encourage you to encrypt sensitive information. Please include:
- A description of the vulnerability.
- Steps to reproduce the issue (including any relevant input files).
- The version of llm-cost affected.
- Any potential impact or exploitation scenarios.

We aim to acknowledge reports within **48 hours** and provide regular updates on our remediation progress.

## Supply Chain & Releases

To reduce supply chain risk, llm-cost uses:

- **Pinned GitHub Actions by SHA** in CI and release workflows
- **Reproducible Zig builds** with a pinned Zig version (currently `0.14.0`)
- **Release artifacts built in CI** from tagged commits
- **Signed binaries and SBOMs** for release assets (via the cross-compile
  workflow and SBOM/signing steps)
- **SLSA Level 2** provenance for release artifacts

See [`docs/VERIFICATION.md`](docs/VERIFICATION.md) for full details and verification
instructions.

---

## Security Considerations

llm-cost is designed as an **offline** CLI tool:

- It does **not** perform network calls at runtime.
- It does **not** handle API keys, passwords, or other credentials.
- It reads from **stdin** or local files and writes JSON/NDJSON to **stdout**.

Defensive measures include:

- **Input size limits** (e.g. max JSON line size for `pipe`)
- **Strict JSON parsing** for `pipe` mode with well-defined error handling
- **Token and cost quotas** (`--max-tokens`, `--max-cost`) to avoid runaway
  processing
- **Fuzz tests and golden tests** to catch crashes and contract regressions

*(Note: Pipe mode is temporarily disabled in v0.5.0 for refactoring, but likely to return in v0.6.0 with these protections.)*

If you discover a case where llm-cost violates these expectations, please
treat it as a potential security bug and report it via the process above.
