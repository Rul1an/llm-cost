# Systeem Architectuur & Pricing DB Breakdown

Dit document beschrijft de technische architectuur van `llm-cost`, met een specifieke focus op de werking van de Pricing Database (`pricedb`).

## 1. High-Level Architectuur

`llm-cost` is ontworpen volgens de **Unix-filosofie** en **Zero-Trust** principes.

*   **Offline First**: De binary bevat *alles* wat nodig is (tokenizers, pricing data, certificaten). Er zijn geen runtime API calls naar buiten nodig (behalve voor `update-db`).
*   **Static Binary**: Geen dependencies (Python, Node.js, etc.). Alles is gecompileerd vanuit Zig naar native machine code.
*   **Pipeline Oriented**: Ontworpen om te werken met `stdin`/`stdout` streams (pipes) voor integratie in CI/CD.

## 2. Pricing Database (PriceDB)

Het hart van de kostenberekening is de `pricedb`. Dit systeem is ontworpen voor maximale veiligheid en determinisme.

### Architectuur van de Laag
De `PricingRegistry` (`src/core/pricing/mod.zig`) bepaalt bij het opstarten welke data gebruikt wordt volgens een strikte prioriteit:

1.  **Cache (`~/.cache/llm-cost/`)**:
    *   Als er een lokaal gedownloade update aanwezig is.
    *   **Integriteitscheck**: De digitale handtekening (Minisign) wordt *altijd* geverifieerd voor het laden.
    *   **Versheidscheck**: Als de data te oud is (default 90 dagen) of corrupt, wordt deze genegeerd (fallback).
2.  **Embedded (`@embedFile`)**:
    *   Als er geen cache is of de cache ongeldig is.
    *   Deze data zit *in* de binary ingebakken ('Release Frozen').
    *   Ook deze data wordt cryptografisch geverifieerd bij het laden om binaire corruptie uit te sluiten.

### Data Formaat
De database bestaat uit twee bestanden:
1.  **`pricing_db.json`**: De feitelijke prijzen.
    *   Structuur: Map van Model ID -> Prijsdefinities.
    *   Prijzen worden intern opgeslagen als `MicroUsd` (i128 integers) om floating-point fouten te voorkomen. Eén unit = $0.000001.
2.  **`pricing_db.json.minisig`**: De cryptografische handtekening.
    *   Gegenereerd met Ed25519 (Minisign).
    *   De publieke sleutel is hardcoded in de source code (`src/core/pricing/crypto.zig`).

### Update Mechanisme (`update-db`)
Het commando `llm-cost update-db` voert een veilige ("secure boot") update uit:

1.  **Download**: Haalt `.json` en `.sig` op van de officiële server (`prices.llm-cost.dev`).
2.  **Verificatie**:
    *   Berekent de hash van de JSON.
    *   Verifieert of de handtekening geldig is voor deze hash met de ingebakken publieke sleutel.
    *   Als dit faalt, wordt de download **direct weggegooid**. Er wordt niets opgeslagen.
3.  **Atomic Write**:
    *   Schrijft naar een tijdelijk bestand (`.tmp`).
    *   Hernoemt (Atomic Move) naar de definitieve locatie. Dit voorkomt corrupte reads tijdens het updaten.

## 3. FinOps & Validatie

De architectuur ondersteunt FinOps "Shift-Left":

*   **Logic Parity**: De tokenizers (BPE) zijn bit-voor-bit compatibel met OpenAI (verified via `test/parity_test.zig`).
*   **Determinisme**: Alle outputs (JSON keys, floats, sortering) zijn deterministisch. Hetzelfde commando levert op elke machine exact dezelfde output (sha256).
*   **FOCUS Integratie**: Import/Export modules (`src/calibrate/focus_import.zig`) vertalen externe billing CSVs naar de interne datastructuren voor 1-op-1 vergelijking.

## Samenvatting Flow

```mermaid
graph TD
    A[Start llm-cost] --> B{Check Cache?};
    B -- Ja & Valid Sig --> C[Load Cache DB];
    B -- Nee / Invalid --> D[Load Embedded DB];
    C --> E[Pricing Registry];
    D --> E;
    E --> F[Command Execution (count/estimate)];
```
