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
| 0.5.x    | ✅         | Actively supported          |
| 0.3.x    | ⚠️         | Critical fixes only         |
| < 0.3.0  | ❌         | No longer supported         |

When in doubt, upgrade to the latest released version before filing a report.

---

## Reporting a Vulnerability

If you believe you have found a security issue in llm-cost, please **do not**
open a public GitHub issue.

Instead, use one of the following channels:

1. **GitHub Security Advisory (preferred)**  
   - Go to the repository's **"Security" → "Advisories"** tab.  
   - Click **"Report a vulnerability"**.  
   - Provide a minimal, reproducible example if possible.

2. **Private Contact (optional)**  
   If you prefer email, please use the contact method referenced in the
   repository description or project website (for example, a dedicated
   `security@…` address).

### What to include

To help us triage quickly, please include:

- Affected version(s) of llm-cost (e.g. `llm-cost 0.5.0`)
- Your OS and environment (Linux/macOS/Windows, Zig version)
- Exact command line invocation (e.g. `llm-cost pipe --model …`)
- Sample input data (or a minimal redacted example)
- A clear description of the impact:
  - Crash / denial of service
  - Information leak
  - Wrong pricing / quota bypass
  - Supply chain / build pipeline issue

### Response Targets

These are *targets*, not hard guarantees, but we aim for:

- **Acknowledgement**: within **72 hours**
- **Initial assessment**: within **7 days**
- **Fix or mitigation**: within **90 days** for most issues

If you believe your issue is being ignored, you may gently follow up via the
same channel.

---

## Supply Chain & Releases

To reduce supply chain risk, llm-cost uses:

- **Pinned GitHub Actions by SHA** in CI and release workflows
- **Reproducible Zig builds** with a pinned Zig version (currently `0.13.x`)
- **Release artifacts built in CI** from tagged commits
- **Signed binaries and SBOMs** for release assets (via the cross-compile
  workflow and SBOM/signing steps)
- **SLSA Level 2** provenance for release artifacts

See [`docs/security.md`](docs/security.md) for full details and verification
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

If you discover a case where llm-cost violates these expectations, please
treat it as a potential security bug and report it via the process above.
