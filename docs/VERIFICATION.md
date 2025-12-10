# Release Verification Guide

This guide explains how to verify the authenticity and integrity of `llm-cost` releases using GitHub Attestations and Sigstore.

## Prerequisities

- [GitHub CLI](https://cli.github.com/) (`gh` v2.49.0+)

## Quick Verification

We provide a script to automate verification:

```bash
./scripts/verify-release.sh <artifact> <tag>
# Example:
./scripts/verify-release.sh llm-cost-linux-x86_64 v0.7.0
```

## Manual Verification

To manually verify an artifact:

1.  **Download the artifact**:
    ```bash
    gh release download v0.7.0 -p "llm-cost-linux-x86_64" --repo Rul1an/llm-cost
    ```

2.  **Verify Attestation**:
    ```bash
    gh attestation verify llm-cost-linux-x86_64 --repo Rul1an/llm-cost
    ```

    **Expected Output:**
    ```
    ✓ Verification successful!
    Subject: llm-cost-linux-x86_64
    Issuer: https://token.actions.githubusercontent.com
    ...
    ```

## Troubleshooting

### "Verification failed: signature mismatch"
- **Cause**: The file has been modified or corrupted.
- **Action**: delete the file and download it again from the official release page.

### "No attestation found"
- **Cause**: Verification was run on a file that wasn't built by the CI pipeline (e.g. built locally).
- **Action**: Use the official release binaries.

## CI/CD Integration

To verify `llm-cost` in your own GitHub Workflows:

```yaml
steps:
  - name: Download llm-cost
    uses: dsaltares/fetch-gh-release-asset@v1
    with:
      repo: 'Rul1an/llm-cost'
      version: 'tags/v0.7.0'
      file: 'llm-cost-linux-x86_64'

  - name: Verify Attestation
    run: gh attestation verify llm-cost-linux-x86_64 --repo Rul1an/llm-cost
```
