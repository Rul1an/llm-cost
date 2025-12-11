# ADR-007: FOCUS Export Field Mapping

**Status**: Accepted  
**Date**: 2025-12-11  
**Deciders**: Product Engineer, Senior Dev, FinOps, Raymond (review)  
**Supersedes**: N/A

---

## Context

`llm-cost` produces cost *estimates* for LLM inference based on static analysis of prompt files. To integrate with enterprise FinOps tooling (Vantage, CloudHealth, CloudZero), we need to export in FOCUS (FinOps Open Cost & Usage Specification) format.

**Challenge**: FOCUS is designed for *actuals* (billed costs), not estimates. We must map our estimate data to FOCUS fields in a way that:

1. Is spec-compliant (validates against FOCUS 1.0 schema)
2. Survives import into real FinOps tools
3. Clearly distinguishes estimates from actual billing data
4. Enables meaningful filtering and grouping

**Constraints**:
- Offline-first: No telemetry, no phone-home
- Must work in airgapped environments
- Tags must survive import (custom `x-*` columns may be stripped)

---

## Decision

### 1. Provider Resolution: Model Registry

**Choice**: Provider is resolved via lookup in the pricing database, not inferred from model name.

**Rationale**:
- Model names are ambiguous: `llama-3-70b` could be Groq, Azure, AWS Bedrock, or Fireworks
- Pricing varies by provider, not just model
- FOCUS requires normalized provider names (`"OpenAI"`, not `"openai"`)
- Single source of truth in pricing DB ensures consistency

**Implementation**:
```json
{
  "models": {
    "gpt-4o": {
      "provider": "OpenAI",
      "input_price_per_mtok": 2.50,
      ...
    }
  }
}
```

**Trade-off**: Requires `update-db` for new models. Mitigated by embedded snapshot pattern — build-time pricing DB in binary, runtime override via `update-db`.

---

### 2. ResourceId: User-Defined `prompt_id`

**Choice**: `ResourceId` maps to user-defined `prompt_id`, not content hash.

**Rationale**:

| Approach | File rename | Content edit | Cost trending |
|----------|-------------|--------------|---------------|
| Content hash | ✓ Same | ❌ Breaks | ❌ Broken |
| Path hash | ❌ Breaks | ✓ Same | ❌ Broken |
| User-defined ID | ✓ Same | ✓ Same | ✓ Preserved |

Content-based identity breaks on every typo fix. User-defined `prompt_id` is stable across renames AND edits, enabling long-term cost trending.

**Change detection** is handled separately via internal `content_hash` (for `diff` output).

**Implementation**:
```toml
[[prompts]]
path = "./prompts/search.txt"
prompt_id = "search"  # Stable, user-defined, never auto-mutated
```

**Trade-off**: Requires explicit ID assignment during `init`. UX mitigates this with suggested defaults from filename.

---

### 3. Field Strategy: Tags (Critical) + x-* (Detail)

**Choice**: Critical metadata in Tags (JSON), detail data in `x-*` extension columns.

**Rationale**:

| Field type | Vantage | CloudHealth | Survival rate |
|------------|---------|-------------|---------------|
| Standard FOCUS | ✓ | ✓ | 100% |
| Tags (JSON) | ✓ Filterable | ✓ Native | ~100% |
| `x-*` columns | Partial | Stripped unless configured | ~50% |

Tags survive import universally. `x-*` columns are spec-compliant but ecosystem support varies.

**Tag allocation** (critical, always preserved):
```json
{
  "llm-cost-type": "estimate",
  "model": "gpt-4o",
  "scenario": "cached",
  "team": "platform",
  "app": "search"
}
```

**Extension columns** (detail, best-effort):
- `x-token-count-input`
- `x-token-count-output`
- `x-cache-hit-ratio`
- `x-content-hash`

**Trade-off**: Tag cardinality limits in FinOps tools. Mitigated by keeping high-cardinality data (like `prompt_id` full hash) in `x-*` columns, not Tags.

---

### 4. Region Field: Omitted

**Choice**: `Region` column omitted from FOCUS output.

**Rationale**:
- LLM inference APIs (OpenAI, Anthropic, Google) are globally distributed
- Region is not a meaningful dimension for cost allocation
- FOCUS spec allows nullable Region
- `"global"` is not a valid ISO region code and causes issues in geo-grouping

**Exception**: Azure OpenAI has region-specific pricing. Future work may add optional Region for Azure models.

---

### 5. BilledCost Handling

**Choice**: `BilledCost = 0.00`, estimates in `EffectiveCost`.

**Rationale**:
- We produce estimates, not billing data
- `BilledCost = 0` is semantically correct — nothing was billed
- `EffectiveCost` carries the estimate value
- `Tags["llm-cost-type"] = "estimate"` makes this explicit

**Trade-off**: Some FinOps tools filter `BilledCost = 0` rows by default. Users may need to adjust filters. Documentation will address this.

---

## FOCUS Output Schema

```csv
BilledCost,EffectiveCost,ListCost,UsageQuantity,UsageUnit,ResourceId,ResourceName,ServiceName,ServiceCategory,Provider,ChargeCategory,Tags,x-token-count-input,x-token-count-output,x-cache-hit-ratio,x-content-hash
0.00,0.0041,0.0052,2370,Tokens,search,prompts/search.txt,LLM Inference,AI and Machine Learning,OpenAI,Usage,"{""llm-cost-type"":""estimate"",""model"":""gpt-4o"",""scenario"":""cached"",""team"":""platform"",""app"":""search""}",1847,523,0.60,a1b2c3
```

**Field mapping summary**:

| FOCUS Field | Source | Notes |
|-------------|--------|-------|
| `BilledCost` | `0.00` | No actual billing |
| `EffectiveCost` | Estimate value | With scenario adjustments |
| `ListCost` | Estimate (no scenario) | Baseline without caching discount |
| `UsageQuantity` | Token count | Input + output |
| `UsageUnit` | `"Tokens"` | Fixed |
| `ResourceId` | `prompt_id` | User-defined, stable |
| `ResourceName` | File path | Human-readable |
| `ServiceName` | `"LLM Inference"` | Fixed |
| `ServiceCategory` | `"AI and Machine Learning"` | FOCUS taxonomy |
| `Provider` | Model registry lookup | From pricing DB |
| `Region` | *(omitted)* | Not applicable |
| `ChargeCategory` | `"Usage"` | Fixed |
| `Tags` | JSON object | Critical metadata |

---

## Security Considerations

### No Telemetry

Behavioral insights (e.g., how often users rename prompts) come from `diff` output patterns in CI logs, which users own. We do not track usage centrally.

**Rationale**: Offline-first is a hard contract with enterprise customers (banks, government, airgapped environments). Any phone-home breaks trust.

### Pricing DB Signatures

FOCUS output depends on pricing DB for Provider resolution. Pricing DB integrity is ensured via:

- minisign (Ed25519) signatures
- Key pinning in binary
- Revocation list checked before signature validation
- Emergency rotation procedure (see `SECURITY.md`)

---

## Validation

### Pre-release Requirements

1. **FOCUS Validator CLI**: CSV must pass `focus-validator` (Linux Foundation tool)
2. **Vantage import test**: Confirm Tags filterable, `x-*` behavior documented
3. **Schema publication**: `focus-output.schema.json` published with v1.0

### Validation Checklist

| Check | Tool | Status |
|-------|------|--------|
| Schema compliance | FOCUS Validator CLI | Pending |
| Tags preserved | Vantage import | Pending |
| Tags filterable | Vantage UI | Pending |
| `x-*` columns | Document behavior | Pending |
| `BilledCost=0` visibility | Vantage UI | Pending |

---

## Consequences

### Positive

- Estimates integrate into existing FinOps dashboards
- Clear distinction between estimates and actuals via Tags
- Stable cost trending via user-defined `prompt_id`
- Provider resolution is reliable and consistent

### Negative

- Requires explicit `prompt_id` assignment (UX overhead at init)
- `BilledCost=0` may require filter adjustment in some tools
- `x-*` columns not universally preserved

### Risks

- **Tag cardinality**: If users add high-cardinality Tags, FinOps tools may throttle. Mitigation: document limits, validate in `check`.
- **FOCUS spec evolution**: FOCUS 2.0 may change field semantics. Mitigation: version our schema, document migration path.

---

## Alternatives Considered

### A. Content Hash for ResourceId

**Rejected**: Breaks cost trending on every content change. Typo fixes would create new "resources" in FinOps dashboards.

### B. Prefix Convention for Provider (`openai/gpt-4o`)

**Rejected**: Breaking change for existing configs, doesn't solve the ambiguity problem for multi-provider models.

### C. `BilledCost = EffectiveCost` (pragmatic lie)

**Rejected**: Semantically incorrect. Would confuse users comparing estimates to actuals. Tags provide clarity.

### D. Region = `"global"` placeholder

**Rejected**: Not a valid ISO region code. Causes issues in geo-grouping dashboards. Nullable is cleaner.

---

## Related Documents

- `roadmap-v1_0-final-v6.md` — Full roadmap with FOCUS export in Phase 4
- `SECURITY.md` — Key rotation procedures
- `docs/focus/*.md` — Provider transformation guides (planned)

---

## Changelog

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-12-11 | Initial decision |
