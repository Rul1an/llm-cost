# Pricing DB Update Checklist (TUF-lite, Offline-first)

This checklist defines the operational procedure for the **Pricing Build Pipeline**.

## 0. Definitions

*   **Artifact**: `pricing_db.zst` (The actual data)
*   **Metadata**: `root.json`, `timestamp.json`, `snapshot.json`, `targets.json`
*   **Offline Keys**: Root, Targets (Cold storage / HSM)
*   **Online Key**: Timestamp (Short-lived, Auto-signing)

## 1. Data Acquisition (Source of Truth)

*Goal: Prefer primary sources and preserve evidence for audits.*

- [ ] **Trigger Identification**: Provider announcement, documentation update, or pricing page change detection.
- [ ] **Evidence Snapshot**:
    - [ ] Store HTML/PDF snapshot of the pricing page.
    - [ ] Record retrieval timestamp + URL + Hash in `pricing/sources/`.
- [ ] **Review**: Two-person review required for any price change >10% or new model families.

## 2. Normalization & Validation

- [ ] **Canonical Schema**: Normalize to `model_id`, `input_per_mtok` (MicroUSD), `output_per_mtok` (MicroUSD).
- [ ] **Determinism Check**: Ensure stable key ordering in JSON/Binary serialization.
- [ ] **Validations**:
    - [ ] Schema validation (types, required fields).
    - [ ] Sanity checks (no negative prices, no massive variance without override).
    - [ ] Monotonic effective dates (history checks).

## 3. Build Artifact

- [ ] Generate deterministic `pricing_db.json`.
- [ ] Compress to `pricing_db.zst`.
- [ ] Compute **SHA256** and **Length** (Bytes).
- [ ] Assign new monotonic version (Format: `YYYYMMDDNN`).

## 4. Generate & Sign TUF-lite Metadata

- [ ] **Update `targets.json`**:
    - [ ] Update artifact hash, length, and version.
    - [ ] Add custom metadata (`generated_at`, `provider_versions`).
    - [ ] **Sign** with OFFLINE Targets Key.
- [ ] **Update `snapshot.json`**:
    - [ ] Pin new `targets.json` hash and version.
    - [ ] **Sign** with Snapshot Key (Offline preferred).
- [ ] **Update `timestamp.json`**:
    - [ ] Pin new `snapshot.json` hash and version.
    - [ ] Set expiry (e.g., `now + 24h`).
    - [ ] **Sign** with ONLINE Timestamp Key.
- [ ] **(Rarely) Update `root.json`**:
    - [ ] Only for key rotation or expiry refresh.
    - [ ] **Sign** with OFFLINE Root Key.

## 5. Publish (Atomic CDN Update)

- [ ] **Upload Artifact**: `PUT /pricing/<version>/pricing_db.zst` (Immutable).
- [ ] **Upload Metadata** (Order matters):
    1.  `snapshot.json`
    2.  `targets.json`
    3.  `timestamp.json` (Last, to enable the update atomically).

## 6. Safety Checks (Pre-release Staging)

- [ ] **Fresh Install**: Verify embedded verification works.
- [ ] **Update**: Verify `update-db` downloads and installs successfully.
- [ ] **Rollback Test**: Verify client rejects an older signed version.
- [ ] **Freeze Test**: Verify client warns/fails if `timestamp.json` is expired.
- [ ] **Corruption Test**: Verify client rejects invalid hash.

## 7. Operational Monitoring

- [ ] **Freeze Alert**: Alert if `timestamp.json` is not updated within 20h (leaving 4h buffer).
- [ ] **Success Rate**: Monitor 200 OK vs errors on CDN.
- [ ] **Telemetry**: (Pro/Ent only) Track `highest_seen_version` distribution.

## 8. Key Rotation Drills (Quarterly)

- [ ] **Root Rotation**: Practice shipping CLI with dual root keys and rotating the chain.
- [ ] **Emergency Revocation**: Simulate key compromise and revocation list update.
