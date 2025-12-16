# Key Rotation Playbook: Pricing Service

**Scope**: Signing Keys for Manifests (Pricing) and Licenses.
**Algorithm**: Ed25519 (RFC 8032).

## 1. Key Inventory

| Key Name | Type | Location | Usage |
| :--- | :--- | :--- | :--- |
| `Root-2025` | Ed25519 Priv | Offline / Safe / HSM | Signs manifests & license certificates. |
| `Root-2025.pub`| Ed25519 Pub  | Embedded in CLI (`src/core/pricing/crypto.zig`) | Validation. |
| `Backup-202X`| Ed25519 Priv | Cold Storage (Paper/Steel) | Disaster Recovery. |

## 2. Routine Rotation (Planned)

*   **Frequency**: Annually (or per Major Version).
*   **Procedure**:
    1.  Generate new keypair `Root-2026`.
    2.  Embed `Root-2026.pub` into `llm-cost` binary (alongside `Root-2025.pub`).
    3.  Release CLI update (e.g., v1.5.0) accepting *both* keys.
    4.  Wait for adoption (e.g., 3-6 months).
    5.  Switch Server Signing to use `Root-2026`.
    6.  Deprecate `Root-2025` in future CLI versions.

## 3. Emergency Rotation (Compromise)

**Trigger**: Confirmed or suspected leak of `Root-2025` private key.

**Procedure**:

1.  **Generate** new keypair `Root-EMERGENCY` immediately.
2.  **Code Change**:
    *   Remove `Root-2025.pub` from `crypto.zig`.
    *   Add `Root-EMERGENCY.pub`.
    *   Add `Root-2025` ID to `REVOKED_KEY_IDS` list in `crypto.zig`.
3.  **Release**: Ship `llm-cost` patch release (e.g., v1.4.1) immediately with "Critical Security Update" notice.
4.  **Resign**:
    *   Re-sign `pricing_manifest.json` and latest `db` with `Root-EMERGENCY`.
    *   (Impact): Old CLI versions will fail signature check (Good! secure fail). They must update.
5.  **Notify**: Email/Blog post explaining the rotation and urging CLI update.

## 4. License Key Rotation

Licensing keys function similarly but breaking them is more painful for paid users.

*   If `License-Key` is compromised, pirates can mint Pro licenses.
*   **Action**: Rotate key + Revoke old ID in CLI.
*   **User Impact**: Users with valid legacy licenses (signed by old key) become invalid.
*   **Mitigation**:
    *   Server provides a "License Refresh" endpoint.
    *   CLI `llm-cost auth refresh` fetches a new license signed by the new key (needs valid auth token).

## 5. Verification Tools

Use `minisign` or internal `license-gen` tool to verify keys before deployment.

```bash
# Verify new key signature
minisign -V -P <NEW_PUB_KEY> -m pricing_manifest.json -x pricing_manifest.sig
```
