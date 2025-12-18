# ADR-011: Calibration Architecture

**Status**: APPROVED
**Date**: 2025-12-18
**Deciders**: @roelschuurkes, @antigravity
**Context**: v1.8.0 "Calibrate" feature design

---

## Context

v1.8.0 introduces cost calibration: comparing estimates against actuals to detect drift. The initial design proposed direct API integrations with Langfuse/Helicone. This creates architectural tension with llm-cost's core contracts:

| Contract | Source | Tension |
|----------|--------|---------|
| **Offline-first** | README, SECURITY.md | API calls require network |
| **No credentials** | Threat model | API keys are credentials |
| **Deterministic output** | Financial kernel | f64 accumulation causes drift |
| **Air-gapped enterprise** | Enterprise pitch | Network dependency |

---

## Decision

### D1: Offline Core + Optional Fetch Binary

**Split architecture**:

```
┌─────────────────────────────────────────────────────────┐
│  llm-cost (core)           │  llm-cost-fetch (optional) │
├─────────────────────────────────────────────────────────┤
│  ✓ Offline                 │  ✗ Requires network        │
│  ✓ No credentials          │  ✗ Stores API keys         │
│  ✓ Air-gapped safe         │  ✗ Calls external APIs     │
│  ✓ Deterministic           │  ✓ Deterministic output    │
├─────────────────────────────────────────────────────────┤
│  llm-cost calibrate \      │  llm-cost-fetch langfuse \ │
│    --actuals data.csv \    │    --output actuals.csv    │
│    --estimates est.json    │                            │
└─────────────────────────────────────────────────────────┘
```

**Rationale**:
- Core binary stays air-gapped (enterprise requirement).
- Fetch binary is opt-in, clearly documented as "network-enabled".
- Users can use any data source that exports FOCUS-compatible CSV.

### D2: Integer Money Throughout (Strict Determinism)

**All monetary values use `i128` MicroUSD**. Floating point parsing is **FORBIDDEN** for money.

```zig
/// 1 MicroUSD = $0.000001 (6 decimal places)
pub const MicroUSD = i128;

// FORBIDDEN: std.fmt.parseFloat(f64, "1.23")
// REQUIRED: Custom decimal parser (sign + integer + fract) -> i128
```

**Drift Calculation**:
- Must be calculated using integer math to minimize precision loss.
- `drift_bps = round((diff_micro * 10000) / estimated_total_micro)`

### D3: Streaming Statistics & Compliance

**Memory Budget**: O(1) per metric via Welford's Algorithm. No full dataset loading.

**FOCUS Compliance**:
- **"FOCUS-compatible subset"**: We do NOT strictly validate all 50+ FOCUS columns.
- We require key columns: `BilledCost`, `UsageQuantity`, `ResourceId`.
- Input must be a valid CSV (RFC 4180 strictness required: quotes, escapes, etc.).

**Implementation Note**:
- `std.mem.splitScalar` is **unsafe** for CSV. Must use a robust state-machine parser.
- **Lifetime Safety**: Keys extracted from the streaming line buffer MUST be interned/copied to an arena before being used as HashMap keys.

### D4: Exit Codes & CLI Contract

We adhere to the existing `sysexits`-based contract. Drift is **data**, not an error.

| Exit Code | Semantics | Usage |
|-----------|-----------|-------|
| 0 | Success | Calibration completed (regardless of drift status) |
| 64 (Usage) | Usage Error | Invalid flags/arguments (e.g., missing --actuals) |
| 65 (Data) | Data Error | Invalid input (CSV/JSON), broken constraints, OR strict drift check fail |
| 70 (Soft) | Software Error | Internal logic error |

**Controlling CI Failure**:
New flag: `--fail-on-drift=<MODE>` (default: `never`)
- `never`: Always exit 0 on success.
- `warn`: Exit 65 if drift status is WARN or ERROR.
- `error`: Exit 65 if drift status is ERROR.

### D5: No Quality Scores in v1.8

**Model routing is cost-only**. We do not attempt to score quality differences between models (e.g. GPT-4 vs GPT-4o-mini) automatically.

---

## Consequences

### Positive

- **Enterprise Ready**: Core remains safe, offline, and deterministic.
- **CI Friendly**: Explicit control over failure conditions via flags.
- **Robustness**: Float-free math and robust parser prevents subtle accounting bugs.

### Negative

- **Multi-binary**: Maintainers must handle `llm-cost-fetch` (though optional).
- **Complexity**: Custom CSV parser and money parser is more work than `std` lib functions.

---

## References

- FOCUS 1.0 Specification
- Welford's Algorithm (Online Variance)
