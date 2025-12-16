# ADR-011: OSS vs Pro/Enterprise Split for "Pricing DB as a Service" (InfraCost-style)

- **Status**: Accepted
- **Date**: 2025-12-15
- **Owners**: Product / Platform / Security
- **Related**: ADR-010

## Context

We want to monetize pricing freshness and governance while preserving:
- **Offline-first usability**
- **OSS trust** (no surprise breakage)
- **Reproducibility** and deterministic estimation

Crucially, we adopt the "InfraCost-style" model: The CLI is OSS and fully functional; the *service* provides operational convenience, SLAs, and enterprise governance.

## Decision: What is Free OSS vs Paid

### Always OSS (Free / Community)

Security and basic usability are basic rights, not paid features.

1.  **Integrity & Security**: TUF-lite verification (anti-tamper/rollback/freeze) applies to **all** tiers.
2.  **Offline Operation**: Every CLI release includes an embedded snapshot. `update-db` caches locally. The tool always works offline.
3.  **Public Updates**: Access to the `stable` update channel (public endpoints).
    *   Rate limits: Fair usage (e.g., 1x/day).
    *   Content: Latest snapshot of public model pricing.
4.  **Staleness Handling**: Default is **WARN-only**. Stale data never causes a hard failure in the default configuration.

**Rationale**: Preventing "3 AM broken pipeline" scenarios is essential for maintaining OSS trust.

### Pro (Paid Convenience, "Set & Forget")

Pro monetizes reduced toil and speed.

1.  **Fast Channel**: Access to pricing updates within 24-48h of provider changes (SLA target).
2.  **No Limits**: Higher/unlimited rate limits on the update API.
3.  **Notifications**: Proactive alerts (Email/Webhook) when pricing changes significantly (major FinOps value).
4.  **Team Licensing**: Shared org-scoped keys, simplifying CI configuration.

### Enterprise (Governance + Air-gapped + Private Data)

Enterprise monetizes governance, compliance, and specific architectural needs.

1.  **Air-Gapped Bundles**: A downloadable, signed "offline pack" containing the full TUF chain and artifacts. Allows updating secure environments without internet access.
2.  **Delegated Org Targets**: The TUF chain supports delegated targets (`targets-org-acme.json`), allowing the inclusion of **Private/Custom Model Pricing** signed specifically for the organization.
3.  **Audit Exports**: FOCUS-compatible pricing changelogs for compliance.
4.  **Policy Enforcement**: Centralized enforcement of strict staleness policies (e.g., "Fail CI if pricing > 7 days old").

## The "Hard Break" Point

We **DO NOT** paywall:
*   Cryptographic integrity
*   Rollback/Freeze protection
*   Basic offline functionality

We **DO** paywall:
*   Operational guarantees (SLA, Frequency)
*   Enterprise governance (Air-gap, Policy)
*   Private data (Custom models)
*   Advanced observability (Notifications, Change feeds)

## API Surface (Conceptual)

### Public
*   `GET /v1/pricing/timestamp.json`
*   `GET /v1/pricing/snapshot.json`
*   `GET /v1/pricing/targets.json`
*   `GET /v1/pricing/<version>/pricing_db.zst`

### Pro/Enterprise (Authenticated)
*   Same endpoints (authorized via Bearer token, higher limits, faster CDN).
*   `POST /v1/license/activate` (Exchange token for offline license cert).
*   `GET /v1/pricing/changes` (Change feed).
*   (Enterprise) `GET /v1/pricing/bundles/latest.zip` (Air-gapped pack).

## Consequences

*   **Trust Model**: Users trust the tool because it doesn't hold their CI hostage.
*   **Value Prop**: Clear upgrade path for teams who need reliability and governance ("Insurance for your cloud bill").
