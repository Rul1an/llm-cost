# Situation Report: Release v0.8.0 (Analytics & Security)
**Date:** 2025-12-11
**Status:** SUCCESS (After Remediation)
**Tag:** `v0.8.0`

## 1. Executive Summary
The v0.8.0 release cycle aimed to deliver two major pillars: **Cost Analytics** (`report` command) and **Supply Chain Hardening** (Secure Boot). While the functional implementation was smooth, the release pipeline experienced significant instability due to upstream dependencies (GitHub Actions/Syft/Cosign). These issues necessitated a complete refactoring of the CI/CD pipeline, resulting in a more robust, modular, and failure-resistant release process.

## 2. Objectives (The Plan)
The scope for v0.8.0 was defined in **Phase C & D** of the roadmap:
*   **Analytics Engine**: Implement research-grade token metrics (Compression Ratio, Fertility).
*   **Secure Boot**: Implement `Minisign` verification for the internal pricing database to prevent tampering.
*   **2025 Pricing**: Update schema for "Reasoning Tokens" (Gemini 2.5, o1).
*   **QA Hardening**: Introduce "Golden Tests" to freeze the CLI contract.

## 3. Execution & Challenges
Development of the core features was completed on schedule. However, the **Deployment Phase** encountered four distinct critical failures during the CI/CD execution on GitHub Actions.

### The "CI Turbulence" Timeline

| Round | Incident | Root Cause | Remediation |
| :--- | :--- | :--- | :--- |
| **1** | **Cosign Network Failure** | `curl` download of Cosign in `zig-cross-compile-action` failed with **HTTP 503**. | **Decoupling**: Switched to the official `sigstore/cosign-installer` action to ensure reliable, cached installation. |
| **2** | **Syft Installer Failure** | Embedded Syft installer in `zig-cross-compile-action` also failed with **HTTP 503**. | **Decoupling**: Switched to `anchore/sbom-action` for SBOM generation, removing the dependency on the build action's embedded tools. |
| **3** | **Missing Directory (`ENOENT`)** | `anchore/sbom-action` failed to find `dist/` directory; faulty ordering. | **Fix**: Added explicit `mkdir -p dist` step *before* SBOM generation. Scoped SBOM scan to `zig-out/bin` directory. |
| **4** | **Artifact Staging Race** | `Stage Artifacts` step tried to copy `.sig` files from `zig-out/` that were already moved to `dist/`. | **Logic Fix**: Removed redundant copy logic. The pipeline now flows linearly: `Build` -> `Sign (to dist)` -> `Publish`. |

## 4. Technical Solutions & Improvements

### A. Pipeline Decoupling
We moved from a "monolithic" build action (Build + SBOM + Sign) to a **modular composite workflow**:
1.  **Build**: `zig-cross-compile-action` (Pure Cross-Compilation).
2.  **SBOM**: `anchore/sbom-action` (Official, Robust).
3.  **Sign**: `cosign sign-blob` (Manual Step, Flexible).
*Benefit: Failures in auxiliary tools no longer break the build, and we gain fine-grained control over versions/caching.*

### B. Codebase Hardening
*   **Secure Boot**: Validates `data/pricing_db.json` signature at runtime using an embedded Ed25519 public key.
*   **Logging**: Standardized on `std.log` instead of `debug.print` for production-grade output.
*   **Golden Tests**: Added `src/golden_test.zig` to enforce JSON schema compliance.

## 5. Final Status
*   **Release**: `v0.8.0` is successfully tagged and built.
*   **Artifacts**: Windows, Linux (glibc/musl), macOS (Arm). All signed and SBOM-attested.
*   **Stability**: The CI pipeline is now significantly more resilient to network flakes than V2.

**Ready for Deployment.**
