# Threat Model: Pricing Updates & Licensing (v1.4.0)

## Assets (wat willen we beschermen)

1. **Integrity** van pricing DB (geen gemanipuleerde prijzen)
2. **Freshness** (geen verborgen verouderde DB blijven gebruiken)
3. **Authenticity** (updates komen van llm-cost signing authority)
4. **License validity** (geen gratis Pro/Ent zonder geldig cert)
5. **Availability** (tool blijft bruikbaar bij netwerk/endpoint issues)
6. **Determinism** (zelfde DB → zelfde resultaten)

## Trust boundaries

* CLI machine (trusted runtime)
* Local filesystem (semi-trusted; kan tampered worden)
* Network/CDN/API (untrusted)
* Signing key infrastructure (must-be-trusted; offline/HSM)

## Attacker models

* MITM / hostile network
* CDN/API compromise (serveert oude of gemanipuleerde files)
* Malicious local user/process (tamper cache/manifest)
* Stolen Pro license token
* Replay/rollback attacker

## Threats & mitigations

### T1: Tampering (DB aangepast)

**Vector:** aanvaller serveert aangepaste pricing_db.json
**Mitigatie:**
* verify DB hash (sha256 uit manifest)
* verify DB signature (minisig/Ed25519)
* atomic write + last_good fallback

### T2: Rollback attack (oude DB)

**Vector:** API serveert een oudere, geldig gesigneerde DB
**Mitigatie:**
* manifest heeft `version` (monotonic) en `generated_at`
* CLI bewaart `highest_seen_version` (persistent)
* reject updates met `version < highest_seen_version` tenzij `--allow-rollback`

### T3: Freeze attack (server blijft oude “latest” serveren)

**Vector:** API blijft dagen/weken dezelfde manifest geven
**Mitigatie:**
* manifest TTL check: `now - generated_at <= max_manifest_age` (bv 7 dagen)
* bij overschrijding: warn; in strict mode: fail
* CLI blijft werken met last_good, maar signaleert risk

### T4: Key compromise (signing key lekt)

**Vector:** attacker kan valid signatures maken
**Mitigatie (MVP):**
* offline signing key (air-gapped/HSM), nooit in API infra
* key rotation plan: public key set (primary + next) in binary
* emergency revoke: ship new CLI release met revoked keyset
  **(Later TUF):** root role + delegations

### T5: Local cache tampering

**Vector:** local file replaced
**Mitigatie:**
* always verify signature/hash before use
* keep `last_good` directory immutable-ish (chmod best effort)
* if invalid → fallback to embedded snapshot + warn

### T6: License forgery

**Vector:** user maakt eigen “pro” license file
**Mitigatie:**
* Ed25519 signature over canonical license payload
* embed license public key in CLI
* include `expires_at`, `features`, `org_id`, `seats`

### T7: License theft / sharing

**Vector:** license file lekt in repo/CI logs
**Mitigatie:**
* support `llm-cost auth login` later (device flow)
* docs: secrets manager, nooit echo’en
* optional: org-level seats + soft enforcement (telemetry opt-in)
* enterprise: allow “offline bundle license” per org

### T8: Clock tampering

**Vector:** user zet klok terug om expiry te omzeilen
**Mitigatie (pragmatisch):**
* grace windows (bv 72h) zodat clock skew niet alles breekt
* record `last_seen_time` locally; if time goes backwards a lot → warn + strict mode fail
* enterprise optie: periodic online refresh (maar tool blijft werken)
