# Verifying llm-cost Releases

This document explains how to verify that your llm-cost binary is authentic and hasn't been tampered with.

## Quick Verification

The fastest way to verify a release:

```bash
# Using GitHub CLI (recommended)
gh attestation verify llm-cost-linux-x86_64 --repo Rul1an/llm-cost
```

Expected output:
```
✓ Verification succeeded!

sha256:abc123... was attested by:
REPO                  PREDICATE_TYPE                    WORKFLOW
Rul1an/llm-cost       https://slsa.dev/provenance/v1    .github/workflows/release.yml@refs/tags/v1.0.0
```

---

## What This Proves

When verification succeeds, you can be confident that:

| Property | Meaning |
|----------|---------|
| **Authenticity** | Binary was built by our CI, not a third party |
| **Integrity** | Binary hasn't been modified since build |
| **Provenance** | You can trace exactly which workflow built it |
| **Source** | Build originated from the official repository |

---

## Verification Methods

### Method 1: GitHub CLI (Easiest)

Requires: [GitHub CLI](https://cli.github.com/) installed

```bash
# Verify any release artifact
gh attestation verify llm-cost-linux-x86_64 --repo Rul1an/llm-cost

# Verify with specific version
gh attestation verify llm-cost-linux-x86_64 \
  --repo Rul1an/llm-cost \
  --owner Rul1an
```

### Method 2: Cosign (More Control)

Requires: [Cosign](https://docs.sigstore.dev/cosign/installation/) installed

```bash
# Download signature and certificate
curl -LO https://github.com/Rul1an/llm-cost/releases/download/v1.0.0/llm-cost-linux-x86_64.sig
curl -LO https://github.com/Rul1an/llm-cost/releases/download/v1.0.0/llm-cost-linux-x86_64.crt

# Verify
cosign verify-blob \
  --signature llm-cost-linux-x86_64.sig \
  --certificate llm-cost-linux-x86_64.crt \
  --certificate-identity-regexp "https://github.com/Rul1an/llm-cost" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  llm-cost-linux-x86_64
```

Expected output:
```
Verified OK
```

### Method 3: SLSA Verifier (Strictest)

Requires: [slsa-verifier](https://github.com/slsa-framework/slsa-verifier) installed

```bash
# Download provenance
curl -LO https://github.com/Rul1an/llm-cost/releases/download/v1.0.0/llm-cost-linux-x86_64.intoto.jsonl

# Verify with source constraints
slsa-verifier verify-artifact llm-cost-linux-x86_64 \
  --provenance-path llm-cost-linux-x86_64.intoto.jsonl \
  --source-uri github.com/Rul1an/llm-cost \
  --source-tag v1.0.0
```

### Method 4: Checksum Only (Basic)

For environments where you can't install verification tools:

```bash
# Download checksums
curl -LO https://github.com/Rul1an/llm-cost/releases/download/v1.0.0/SHA256SUMS.txt

# Verify checksum
sha256sum -c SHA256SUMS.txt --ignore-missing
```

⚠️ **Note:** Checksum verification only confirms file integrity, not authenticity. An attacker who replaces the binary could also replace the checksum file.

---

## Understanding Signatures

### What's in the `.sig` file?

The `.sig` file contains a base64-encoded signature created by Cosign using keyless signing (OIDC).

### What's in the `.crt` file?

The `.crt` file contains the signing certificate, which proves:
- The signature was created during a GitHub Actions workflow
- The workflow ran in the `Rul1an/llm-cost` repository
- The identity is bound to GitHub's OIDC provider

### What's in the `.intoto.jsonl` file?

This is the SLSA provenance attestation containing:
- **Subject**: The artifact hash being attested
- **Predicate**: Build details (repository, workflow, commit, etc.)
- **Signature**: Cryptographic proof of the attestation

---

## Understanding the SBOM

Each release includes a Software Bill of Materials (SBOM) in CycloneDX format:

```bash
# View SBOM
cat llm-cost-linux-x86_64.cdx.json | jq '.'

# List components
cat llm-cost-linux-x86_64.cdx.json | jq '.components[].name'
```

The SBOM lists:
- Build tools (Zig compiler version)
- Standard library components
- Any embedded dependencies

---

## Verification Failures

### "No attestations found"

```
Error: no attestations found for subject
```

**Causes:**
- Binary was downloaded from unofficial source
- Binary was modified after download
- Attestation hasn't propagated yet (wait 5 minutes)

**Solution:** Re-download from official GitHub release page.

### "Certificate identity mismatch"

```
Error: certificate identity did not match
```

**Causes:**
- Binary was built by different workflow/repository
- Possible supply chain attack

**Solution:** Do not use this binary. Report to maintainers.

### "Signature verification failed"

```
Error: verifying blob: invalid signature
```

**Causes:**
- Binary was modified after signing
- Signature file is corrupted
- Wrong signature file for this binary

**Solution:** Re-download both binary and signature.

---

## Security Guarantees

### What SLSA Level 2 Means

| Guarantee | Description |
|-----------|-------------|
| Build process documented | Workflow file is public |
| Provenance is signed | Can't be forged without GitHub credentials |
| Tampering is detectable | Any modification breaks signature |

### What It Does NOT Guarantee

| Not Guaranteed | Why |
|----------------|-----|
| Code is bug-free | Provenance ≠ code review |
| No vulnerabilities | Use SBOM for vulnerability scanning |
| Source code is safe | You still need to trust the maintainers |

---

## Integrating Verification in CI/CD

### GitHub Actions

```yaml
- name: Download llm-cost
  run: |
    curl -LO https://github.com/Rul1an/llm-cost/releases/download/v1.0.0/llm-cost-linux-x86_64
    chmod +x llm-cost-linux-x86_64

- name: Verify llm-cost
  run: |
    gh attestation verify llm-cost-linux-x86_64 --repo Rul1an/llm-cost
  env:
    GH_TOKEN: ${{ github.token }}
```

### Docker

```dockerfile
FROM alpine:latest

# Install verification tools
RUN apk add --no-cache curl cosign

# Download and verify
RUN curl -LO https://github.com/Rul1an/llm-cost/releases/download/v1.0.0/llm-cost-linux-x86_64 \
    && curl -LO https://github.com/Rul1an/llm-cost/releases/download/v1.0.0/llm-cost-linux-x86_64.sig \
    && curl -LO https://github.com/Rul1an/llm-cost/releases/download/v1.0.0/llm-cost-linux-x86_64.crt \
    && cosign verify-blob \
         --signature llm-cost-linux-x86_64.sig \
         --certificate llm-cost-linux-x86_64.crt \
         --certificate-identity-regexp "https://github.com/Rul1an/llm-cost" \
         --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
         llm-cost-linux-x86_64 \
    && chmod +x llm-cost-linux-x86_64 \
    && mv llm-cost-linux-x86_64 /usr/local/bin/llm-cost
```

---

## Questions?

If verification fails unexpectedly or you have security concerns, please:

1. Open an issue: https://github.com/Rul1an/llm-cost/issues
2. Email: security@example.com (for sensitive reports)

Do NOT use unverified binaries in production.
