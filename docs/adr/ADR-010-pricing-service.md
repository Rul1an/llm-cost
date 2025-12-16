# ADR-010: TUF-lite Secure Pricing DB Updates (Offline-first)

**Status**: Accepted
**Date**: 2025-12-15
**Owners**: Platform FinOps / Security
**Related**: Threat Model v1.4.0 (Pricing Updates & Licensing)

## Context

`llm-cost` ships with an embedded pricing snapshot and supports `update-db` to fetch newer pricing.
We need strong guarantees that:
1) **Integrity/Authenticity**: Pricing data cannot be silently tampered with.
2) **Anti-Rollback**: Clients cannot be tricked into accepting older signed data (reintroducing bugs/lower prices).
3) **Anti-Freeze**: Clients can detect if a server is stuck serving old "latest" data.
4) **Availability**: The tool stays usable offline and under partial outages.

TUF (The Update Framework) is the standard design for secure update systems. We adopt a minimal "TUF-lite" subset that still covers the key threats: tampering, rollback, and freeze.

## Decision

Adopt a **TUF-lite metadata chain** for pricing DB updates, with a `manifest.json` compatibility wrapper for simplified client logic.

### 1. Roles & Metadata Files

We use 4 metadata files (standard TUF roles), each signed:

| Role | File | Key Type | Purpose | Expiry |
|:---|:---|:---|:---|:---|
| **Root** | `root.json` | Offline | Pins public keys for other roles. Supports rotation. | Long (1y) |
| **Timestamp** | `timestamp.json` | Online | Pins `snapshot.json`. Prevents freeze attacks. | Short (24h) |
| **Snapshot** | `snapshot.json` | Offline/Online | Pins `targets.json` hash/version. Ensures consistent view. | Medium (1w) |
| **Targets** | `targets.json` | Offline | Pins artifacts (`pricing_db.zst`). Contains custom metadata. | Medium (1m) |

### 2. The Artifact

*   `pricing_db.zst`: Contains the pricing registry in a deterministic serialized format (e.g., canonical JSON or binary).
*   Validation: Client validates sha256 + length against the entry in `targets.json`.

### 3. Compatibility Wrapper (`manifest.json`)

To simplify the Zig implementation while gaining TUF properties, we may serve a `manifest.json` that aggregates the necessary verification data (or acts as the entry point equivalent to Timestamp+Snapshot+Targets pointers) for the client. However, the logical verification flow **MUST** follow TUF-lite steps:

### 4. Client Update Algorithm (The "TUF-lite" Logic)

On `llm-cost update-db`:

1.  **Load Trusted Root**: Start with embedded `root.json` (or persisted updated root).
2.  **Fetch Timestamp**: Verify signature (Online Key) and check expiry (`now < expires_at`). *Detects freeze.*
3.  **Fetch Snapshot**: Verify signature and match hash/version from Timestamp.
4.  **Fetch Targets**: Verify signature and match hash/version from Snapshot.
5.  **Rollback Protection**:
    *   Compare `db_version` in Targets against persisted `highest_seen_db_version`.
    *   **Reject** if lower (unless `--allow-rollback` is set).
6.  **Download Artifact**: Fetch `pricing_db.zst`. Verify SHA256 + Length against Targets.
7.  **Atomic Install**:
    *   Write to `~/.cache/llm-cost/pricing/next/`
    *   Fsync.
    *   Rotate: `current` → `last_good`, `next` → `current`.
8.  **Persist State**: Update `highest_seen_db_version` and `last_seen_time`.

### 5. Freshness / Freeze Signaling

*   **Default (OSS)**: If Timestamp is expired or `db_version` is old (>30 days): **WARN only**. Never break basic functionality.
*   **Strict (Policy/Ent)**: If configured (e.g., `LLM_COST_STRICT=1`), **FAIL** the operation to prevent using stale data in critical pipelines.

## Implementation Details

*   **Canonical Signing**: Signatures must be generated over **canonicalized bytes** (or a hash of the binary format), NOT over raw JSON strings that are subject to whitespace/formatting changes.
*   **Crypto**: Ed25519 for all signatures.
*   **Storage Layout**:
    ```
    ~/.cache/llm-cost/
    ├── current/
    │   ├── pricing_db.zst
    │   └── metadata/ (root, targets, etc.)
    ├── last_good/
    └── state.json
    ```

## Operational Considerations

*   **Key Compromise**:
    *   Online Timestamp key is most at risk. Revocation involves rotating the key in the Root role.
    *   Offline Root/Targets keys are kept in cold storage/HSM.
*   **Network Outage**: CLI degrades gracefully to `current` or `embedded` snapshot.
*   **Clock Skew**: Use a "last seen time" heuristic to warn if the system clock jumps backwards, addressing simple expiry bypass attempts.

## Alternatives Considered

1.  **Single `minisig` on DB**: Rejected. Fails to prevent freeze attacks (server replaying old valid file) or rollback attacks without ad-hoc state logic.
2.  **Full TUF (Python Reference)**: Rejected. Too complex to integrate into a lightweight Zig binary. TUF-lite provides 80/20 benefit.

## Consequences

*   **Positive**: Strong supply-chain security standard. "Pricing as Code" becomes trustworthy.
*   **Negative**: Requires a more complex "Pricing Build Pipeline" to generate and sign metadata roles.
