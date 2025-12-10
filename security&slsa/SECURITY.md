# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.x.x   | :white_check_mark: |
| < 1.0   | :x:                |

## Supply Chain Security

### SLSA Level 2 Compliance

All releases of llm-cost are built with **SLSA Build Level 2** compliance:

- ✅ **Signed Provenance**: Every release artifact has cryptographic provenance
- ✅ **SBOM Included**: CycloneDX Software Bill of Materials for each binary
- ✅ **Keyless Signing**: Artifacts signed via Sigstore/Cosign OIDC
- ✅ **Verifiable**: Users can verify authenticity before use

### Verifying Releases

Before using any release, verify its authenticity:

```bash
# Using GitHub CLI
gh attestation verify <artifact> --repo Rul1an/llm-cost

# Using Cosign
cosign verify-blob \
  --signature <artifact>.sig \
  --certificate <artifact>.crt \
  --certificate-identity-regexp "https://github.com/Rul1an/llm-cost" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  <artifact>
```

See [VERIFICATION.md](docs/VERIFICATION.md) for detailed instructions.

## Reporting a Vulnerability

### Do NOT

- Open a public GitHub issue for security vulnerabilities
- Discuss vulnerabilities in public channels
- Exploit vulnerabilities against other users

### Do

1. **Email**: Send details to `security@example.com`
2. **Include**:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)
3. **Wait**: Allow 90 days for a fix before public disclosure

### What to Expect

| Timeframe | Action |
|-----------|--------|
| 24 hours | Acknowledgment of report |
| 7 days | Initial assessment |
| 30 days | Fix development (for valid issues) |
| 90 days | Public disclosure (coordinated) |

### Scope

In scope:
- llm-cost binary vulnerabilities
- Build pipeline compromise
- Supply chain attacks
- Memory safety issues

Out of scope:
- Vulnerabilities in Zig compiler itself (report to ziglang.org)
- Issues in dependencies (report to respective maintainers)
- Social engineering attacks

## Security Design

### Build Process

```
Source Code (GitHub)
       │
       ▼
┌─────────────────┐
│ GitHub Actions  │ ← Isolated build environment
│ (ubuntu-latest) │
└─────────────────┘
       │
       ▼
┌─────────────────┐
│   Zig Build     │ ← Deterministic compilation
│   (ReleaseFast) │
└─────────────────┘
       │
       ├──────────────────┬──────────────────┐
       ▼                  ▼                  ▼
┌─────────────┐   ┌─────────────┐   ┌─────────────┐
│   Binary    │   │    SBOM     │   │  Signature  │
└─────────────┘   └─────────────┘   └─────────────┘
       │                  │                  │
       └──────────────────┴──────────────────┘
                         │
                         ▼
                  GitHub Release
                  (with attestation)
```

### Threat Model

| Threat | Mitigation |
|--------|------------|
| Compromised maintainer | Signed commits, branch protection |
| CI/CD compromise | SLSA provenance, signature verification |
| Binary tampering | Cosign signatures, checksums |
| Dependency attacks | Minimal dependencies (stdlib only) |
| Supply chain | SBOM for transparency |

### Minimal Attack Surface

llm-cost is designed with minimal dependencies:

- **No external crates/packages**: Only Zig standard library
- **No network code**: Purely offline operation
- **No file writes**: Read-only by default
- **Static linking**: Self-contained binary

## Security Updates

Security fixes are released as:
- **Patch versions** (1.0.x) for non-breaking fixes
- **Immediate releases** for critical vulnerabilities

Subscribe to releases for notifications:
https://github.com/Rul1an/llm-cost/releases.atom

## Acknowledgments

We thank the following for responsible disclosure:
- (None yet)

---

*Last updated: December 2025*
