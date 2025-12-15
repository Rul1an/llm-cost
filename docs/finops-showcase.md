# FinOps Validation Showcase

This guide demonstrates how to verify the **FinOps Validation Suite** yourself.

## 1. Quick Start (The "Smoke Test")

Run the P0 suite (Gatekeeper) to verify core logic determinism and safety.

```bash
./scripts/finops/run_finops_suite.sh p0
```

**Expected Output:**
```text
✅ Determinism: factors.toml byte-identical
✅ Missing columns: hard error + message
✅ PII guard: no leakage
✅ FinOps suite 'p0' complete
```

## 2. The "Fail-Fast" Policy

`llm-cost` refuses to process corrupt data. This is a feature, not a bug.

**Try it:**
```bash
# Create a bad CSV (missing columns)
echo "ResourceId,BilledCost" > bad.csv
echo "req-1,0.05" >> bad.csv

# Run calibrate
./zig-out/bin/llm-cost calibrate \
  --estimates testdata/finops/small/estimates.json \
  --actuals bad.csv || echo "Exit Code: $?"
```

**Result:**
```text
Error: CSV missing required columns:
  - ChargePeriodStart
Exit Code: 2
```

## 3. Generating the Audit Report

Generate the same JSON audit artifact that runs in CI/CD.

```bash
# Set Policy
export FINOPS_MAX_DRIFT_BPS=10
export FINOPS_FAIL_FAST=true

# Run Renderer
python3 tools/finops/render_report.py
```

**View the Artifact:**
```bash
cat reports/audit.json
```
```json
{
  "focus_version": "1.1",
  "policy": {
    "fail_fast": true,
    "max_drift_bps": 10.0
  },
  "results": {
    "logic_determinism": {
      "passed": true,
      "sha256": "..."
    }
  }
}
```
