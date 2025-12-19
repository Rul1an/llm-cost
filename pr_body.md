feat: Add cardinality guardrail to calibrate stats

**What**: Add cardinality guardrail to `calibrate` stats; cap unique model keys with Error/Degrade policies.

**Why**: Prevent memory exhaustion when input contains adversarial high-cardinality "model names" or garbage data.

**How**:
- **Check-then-intern**: Lookup keys on raw slice before interning to avoid Arena explosion.
- **Strict Option A**: `max_unique_resources` is a hard limit on map entries.
- **Degrade**: If enabled, `__other__` is pre-inserted and counts towards the cap. Overflow aggregates to this bucket.
- **Observability**: Emits `cardinality_truncated` status and `unique_resources_seen` count.

**Tests**:
- `zig build test-cardinality` (strict limit verification)
- Full regression suite (53 tests) passing.
