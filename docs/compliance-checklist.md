# llm-cost – Security & Compliance Checklist

Dit document is bedoeld voor security-, infra- en platform-teams die llm-cost willen goedkeuren of uitrollen in een organisatiecontext.

---

## 1. Productoverzicht

- **Type:** CLI-tool voor *offline* token counting & pricing.
- **Gebruik:**
  - `tokens` – aantal tokens bepalen
  - `price` – kosten berekenen op basis van tokens + model
  - `pipe` – JSONL stream verrijken met tokens & kosten
- **Belangrijk:**
  - Geen netwerk-verzoeken; draait volledig lokaal.
  - Geen opslag van API-keys, wachtwoorden of secrets.
  - Leest van stdin of bestanden, schrijft naar stdout/stderr.

Meer details: zie `README.md` en `SECURITY.md`.

---

## 2. Ondersteunde versies

Controleer dat je een **ondersteunde** versie gebruikt:

| Version range | Status                  |
|---------------|-------------------------|
| `0.5.x`       | ✅ Volledig ondersteund |
| `0.3.x`       | ⚠️ Alleen critical fixes |
| `< 0.3.0`     | ❌ Niet ondersteund     |

Zie `SECURITY.md` voor de actuele matrix.

**Checklist:**

- [ ] In productie wordt minimaal **v0.5.0** of hoger gebruikt.
- [ ] Patching-policy: upgrade binnen X dagen na nieuwe minor/patch.

---

## 3. Supply Chain & Build Trust

### 3.1. Release-bron

- Officiële releases via GitHub Releases (tag `vX.Y.Z`).
- CI-build vanaf getagde commits.
- Geen handmatig geüploade binaries.

**Checklist:**

- [ ] Binaries alleen downloaden van het officiële GitHub Release van het project.
- [ ] Geen “hergehoste” of interne kopieën zonder verificatie.

### 3.2. Ondertekening & SLSA

Elke release bevat:

- Binary: `llm-cost-<platform>`
- Signature: `llm-cost-<platform>.sig`
- Certificaat: `llm-cost-<platform>.crt`
- SBOM: `llm-cost-<platform>.cdx.json`
- SLSA Level 2 provenance (beschreven in `docs/security.md`).

**Verificatie (hoog-niveau):**

1. **Checksum controleren**

   ```bash
   sha256sum llm-cost-<platform>
   # Vergelijk met checksum uit release notes / CHECKSUMS-bestand
   ```

2. **Signature & identiteit controleren** (cosign-achtig voorbeeld)

   ```bash
   cosign verify-blob \
     --signature llm-cost-<platform>.sig \
     --certificate llm-cost-<platform>.crt \
     --certificate-identity 'https://github.com/<ORG>/llm-cost/.github/workflows/release.yml@refs/tags/vX.Y.Z' \
     --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
     llm-cost-<platform>
   ```

3. **SLSA-provenance controleren**

   Zie `docs/security.md` voor concrete slsa-verifier commando’s.

**Checklist:**

- [ ] SHA256 checksum vergeleken met officiële values.
- [ ] Signature gevalideerd tegen verwachte GitHub workflow identity.
- [ ] SLSA provenance geverifieerd (Level 2) voor gebruikte binaries.
- [ ] SBOM (`*.cdx.json`) opgeslagen voor intern software inventory / SBOM tooling.

---

## 4. Runtime security & deployment

### 4.1. Executie-context

- Kan draaien als normale non-root user.
- Geen netwerktoegang nodig.
- Werkt op Linux/macOS/Windows.

**Aanbevelingen:**

- Draai bij voorkeur:
  - als non-root service/gebruikersaccount;
  - in een gecontaineriseerde omgeving (Docker/Kubernetes) zonder netwerk;
  - met read-only binaries en beperkte toegang tot input-data.

**Checklist:**

- [ ] llm-cost draait als non-root.
- [ ] Container/VM heeft geen uitgaande netwerktoegang nodig voor llm-cost.
- [ ] Toegang tot inputbestanden is beperkt tot noodzakelijke paden.

### 4.2. Data & privacy

- **llm-cost:**
  - Slaat geen data op schijf op, tenzij expliciet geredirect.
  - Leest input alleen van stdin of expliciete files.
  - Schrijft resultaten naar stdout (en logging naar stderr).

**Checklist:**

- [ ] Logging (stderr) wordt eventueel naar een veilig log-systeem gepiped.
- [ ] Er worden geen gevoelige gegevens gelogd buiten de JSONL-output (bijv. invalid JSON wordt als foutregel gelogd, niet opnieuw in detail gedumpt).
- [ ] Retentie van logs en outputs voldoet aan interne data policies.

---

## 5. Resource limits & input-validatie

- **Inputlimieten:**
  - JSONL line size limiet (bijv. 10MB per regel).
  - `pipe` heeft `--max-tokens` en `--max-cost` quota om runaway-cases te voorkomen.
- **Validatie:**
  - Strikte JSON parsing.
  - Per-line error handling (fail-on-error optie).
- **Testing:**
  - Fuzz tests voor tokenizer en JSON pipeline.
  - Golden tests voor CLI contract.
  - Parity tests t.o.v. referentie-tokenizers.

**Checklist:**

- [ ] Indien `pipe` wordt gebruikt: `--max-tokens` en/of `--max-cost` zijn ingesteld in productie-pipelines.
- [ ] `--fail-on-error` wordt gebruikt waar “hard fail” gewenst is (bijv. strikte ETL jobs).
- [ ] Fuzz/golden/parity tests worden in CI gedraaid (`zig build test`, `zig build fuzz`, `zig build test-golden`, `zig build test-parity`).

---

## 6. Operational policy

### Upgrades

- Volg de release notes op GitHub.
- Test nieuwe versies eerst in staging:
  - golden tests draaien op interne corpora;
  - benchmark-run (`zig build bench-bpe`, etc.) voor regressies.

### Incident response

- Bij vermoeden van kwetsbaarheid:
  - Gebruik GitHub Security Advisories om privé een issue te openen.
  - Zie `SECURITY.md` voor SLA: 72h acknowledgment, 7 dagen eerste triage, 90 dagen fix/mitigatie.

**Checklist:**

- [ ] Interne owner (team/persoon) vastgelegd voor llm-cost.
- [ ] Upgrade-proces gedefinieerd (staging → productie).
- [ ] Incidentproces verwijst naar `SECURITY.md` voor responsible disclosure.
