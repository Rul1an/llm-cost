# llm-cost v1.2.0 Proof of Value Test Suite

**Version**: 1.0  
**Date**: 2025-12-14  
**Author**: FinOps Data Engineering  
**Framework**: FinOps Foundation 2025 Maturity Model

---

## Philosophy

> "Don't test that code works. Test that it solves real problems."

Dit document focust op **proof of value** — scenarios waar FinOps teams binnen 30 minuten kunnen zien dat llm-cost een echt probleem oplost.

### 2025 FinOps Context

| Trend | Implicatie voor llm-cost |
|-------|--------------------------|
| AI spend groeit 40% YoY | Cost governance is niet optioneel |
| FinOps Foundation AI WG standaarden | FOCUS compliance is table stakes |
| Unit economics focus | Per-prompt attribution, niet per-service |
| Shift-left FinOps | CI/CD integration, niet monthly reviews |
| Multi-cloud + multi-provider | Unified view across OpenAI, Anthropic, etc. |

---

## Tier 1: "Show Me The Money" (5-Minute Demos)

*Doel: CFO/VP Engineering kunnen binnen 5 minuten de waarde zien*

### POV-1: The $50K Regression That Never Shipped

**Stakeholder**: VP Engineering, CFO  
**Time to Demo**: 3 minutes  
**Impact**: Prevent 6-figure annual cost explosion

**Story**: Junior engineer adds "chain of thought" to production prompt. Token count goes from 500 to 5000. Without governance, this ships and costs $50K/month extra.

```bash
# === SETUP ===
mkdir -p prompts
cat > prompts/summarize-v1.txt << 'EOF'
Summarize this article in 2 sentences.
EOF

cat > prompts/summarize-v2.txt << 'EOF'
You are an expert analyst. Think through this step by step.

First, identify the main thesis of the article.
Then, list all supporting arguments.
Next, evaluate the strength of evidence.
Consider counterarguments that might exist.
Assess the author's credibility and potential biases.
Finally, synthesize everything into a comprehensive summary.

Think out loud about each step before providing your final answer.
Provide your reasoning in <thinking> tags before the summary.
EOF

# === DEMO ===
echo "=== Current Production Cost ==="
llm-cost estimate prompts/summarize-v1.txt --model gpt-4o --calls 100000
# Output: $150.00/month

echo ""
echo "=== PR #4521: 'Improve summary quality' ==="
llm-cost estimate prompts/summarize-v2.txt --model gpt-4o --calls 100000
# Output: $1,500.00/month

echo ""
echo "=== CI Gate Result ==="
llm-cost check prompts/summarize-v2.txt \
  --baseline prompts/summarize-v1.txt \
  --fail-on-increase 100%
# Exit 1: BLOCKED
# Message: "Cost increase of 900% exceeds threshold of 100%"
```

**Success Criteria**:
- [ ] 900% increase detected in <1 second
- [ ] Clear error message with dollar impact
- [ ] Exit code 1 blocks CI pipeline

**Value Statement**: 
> "This would have cost us $16,200/year. llm-cost caught it before merge."

---

### POV-2: The Cache Assumption That Cost $30K

**Stakeholder**: Platform Team Lead, FinOps Manager  
**Time to Demo**: 5 minutes  
**Impact**: Identify root cause of 3x budget overrun

**Story**: Team assumes 80% prompt cache hit rate based on Anthropic docs. Reality: cache TTL is shorter than their traffic patterns. Actual hit rate is 25%.

```bash
# === SETUP ===
cat > estimates-with-cache-assumption.json << 'EOF'
{
  "prompts": [
    {
      "resource_id": "product-search",
      "model": "claude-3-5-sonnet",
      "tokens_input": 2000,
      "tokens_output": 500,
      "calls_per_month": 500000,
      "assumed_cache_hit_ratio": 0.80,
      "monthly_cost_usd": 2250.00
    }
  ],
  "assumptions": {
    "cache_hit_ratio": 0.80,
    "source": "Anthropic documentation default"
  }
}
EOF

cat > actuals-from-billing.focus.csv << 'EOF'
ChargePeriodStart,ChargePeriodEnd,ResourceId,BilledCost,ChargeCategory,Tags
2025-01-01,2025-01-31,product-search,6750.00,Usage,"{""x-cache-hit-ratio"":""0.25"",""model"":""claude-3-5-sonnet""}"
EOF

# === DEMO ===
echo "=== Calibration Analysis ==="
llm-cost calibrate \
  --estimates estimates-with-cache-assumption.json \
  --actuals actuals-from-billing.focus.csv

# Expected Output:
# ┌─────────────────────────────────────────────────────────────────┐
# │  ⚠️  SIGNIFICANT DRIFT DETECTED                                 │
# ├─────────────────────────────────────────────────────────────────┤
# │                                                                 │
# │  Parameter         Assumed    Actual     Drift                  │
# │  ─────────────────────────────────────────────────────────────  │
# │  cache_hit_ratio   80%        25%        -55pp  ⛔ CRITICAL     │
# │                                                                 │
# │  Cost Impact:                                                   │
# │    Estimated:  $2,250.00                                        │
# │    Actual:     $6,750.00                                        │
# │    Overrun:    $4,500.00/month (+200%)                          │
# │                                                                 │
# │  Root Cause Analysis:                                           │
# │    Cache hit ratio 55 percentage points lower than assumed.     │
# │    Likely causes:                                               │
# │    - Cache TTL shorter than traffic pattern window              │
# │    - High request diversity (low prompt reuse)                  │
# │    - Cache eviction due to memory pressure                      │
# │                                                                 │
# │  Recommendation:                                                │
# │    Update cache_hit_ratio to 0.25 in llm-cost.toml             │
# │    Annual impact: $54,000 budget correction                     │
# │                                                                 │
# └─────────────────────────────────────────────────────────────────┘
```

**Success Criteria**:
- [ ] Cache drift identified as root cause
- [ ] Dollar impact clearly quantified
- [ ] Actionable recommendation provided

**Value Statement**:
> "We thought it was traffic growth. Calibrate showed it was cache misconfiguration. Fixed config, saved $4,500/month."

---

### POV-3: Chargeback Report in 60 Seconds

**Stakeholder**: Finance Controller, VP Product  
**Time to Demo**: 2 minutes  
**Impact**: Eliminate 8 hours/month manual allocation work

**Story**: Platform team needs to charge back AI costs to product teams. Currently: export from 3 provider dashboards, manual Excel pivot tables, arguments about allocation methodology.

```bash
# === SETUP ===
cat > llm-cost.toml << 'EOF'
[defaults]
model = "gpt-4o"

[[prompts]]
id = "search-autocomplete"
path = "prompts/search.txt"
calls_per_month = 1000000
[prompts.tags]
team = "discovery"
product = "search"
cost_center = "CC-2001"

[[prompts]]
id = "recommendation-engine"
path = "prompts/recs.txt"
model = "claude-3-5-sonnet"
calls_per_month = 500000
[prompts.tags]
team = "personalization"
product = "homepage"
cost_center = "CC-2002"

[[prompts]]
id = "content-moderation"
path = "prompts/moderate.txt"
model = "gpt-4o-mini"
calls_per_month = 5000000
[prompts.tags]
team = "trust-safety"
product = "ugc"
cost_center = "CC-2003"
EOF

# === DEMO ===
echo "=== Generate Chargeback Report ==="
llm-cost export --manifest llm-cost.toml --format focus > chargeback-jan-2025.csv

echo ""
echo "=== Preview ==="
head -5 chargeback-jan-2025.csv

echo ""
echo "=== Summary by Cost Center ==="
llm-cost report --manifest llm-cost.toml --group-by cost_center

# Expected Output:
# ┌──────────────┬─────────────────────┬──────────────┐
# │ Cost Center  │ Team                │ Monthly Cost │
# ├──────────────┼─────────────────────┼──────────────┤
# │ CC-2001      │ discovery           │ $2,500.00    │
# │ CC-2002      │ personalization     │ $7,875.00    │
# │ CC-2003      │ trust-safety        │ $750.00      │
# ├──────────────┼─────────────────────┼──────────────┤
# │ TOTAL        │                     │ $11,125.00   │
# └──────────────┴─────────────────────┴──────────────┘
#
# Export: chargeback-jan-2025.csv (FOCUS 1.0 compliant)
# Ready for: Vantage, CloudHealth, internal warehouse
```

**Success Criteria**:
- [ ] FOCUS-compliant CSV generated
- [ ] Tags preserved for filtering
- [ ] Cost center rollup correct

**Value Statement**:
> "Monthly chargeback went from 8-hour Excel exercise to 60-second CLI command."

---

## Tier 2: Data Quality Gauntlet

*Doel: Bewijs dat llm-cost niet crasht op echte productie data*

### POV-4: The Vantage Prefix Problem

**Context**: Vantage prefixes ResourceIds with `custom-providername/`. Dit breekt naive exact-match joins.

```bash
cat > estimates.json << 'EOF'
{"prompts": [
  {"resource_id": "search-query", "cost_usd": 100.00},
  {"resource_id": "summarize", "cost_usd": 50.00}
]}
EOF

cat > actuals-vantage.focus.csv << 'EOF'
ChargePeriodStart,ChargePeriodEnd,ResourceId,BilledCost,ChargeCategory
2025-01-01,2025-01-31,custom-llmcost/search-query,112.00,Usage
2025-01-01,2025-01-31,custom-llmcost/summarize,58.00,Usage
EOF

# Test: Strict matching (should fail)
llm-cost calibrate --estimates estimates.json --actuals actuals-vantage.focus.csv --matching strict
# Expected: "Match rate: 0% - No matching ResourceIds found"

# Test: Fuzzy matching (should work)
llm-cost calibrate --estimates estimates.json --actuals actuals-vantage.focus.csv --matching fuzzy
# Expected: "Match rate: 100% - Stripped prefix 'custom-llmcost/'"
```

**Success Criteria**:
- [ ] Strict mode correctly reports 0% match
- [ ] Fuzzy mode strips known prefixes
- [ ] Clear logging of transformations applied

---

### POV-5: Credits, Refunds, and Negative Costs

**Context**: Enterprise billing bevat credits, refunds, en promo's. Naive sum() geeft verkeerde totals.

```bash
cat > actuals-with-credits.focus.csv << 'EOF'
ChargePeriodStart,ChargePeriodEnd,ResourceId,BilledCost,ChargeCategory
2025-01-01,2025-01-31,search-query,100.00,Usage
2025-01-01,2025-01-31,search-query,-15.00,Credit
2025-01-01,2025-01-31,search-query,-5.00,Refund
2025-01-01,2025-01-31,summarize,50.00,Usage
2025-01-01,2025-01-31,summarize,0.00,Usage
EOF

llm-cost calibrate --estimates estimates.json --actuals actuals-with-credits.focus.csv

# Expected:
# ResourceId: search-query
#   Usage:   $100.00
#   Credits: -$15.00
#   Refunds: -$5.00
#   Net:     $80.00  ← Correct
#
# ResourceId: summarize
#   Usage:   $50.00
#   Net:     $50.00
#
# ℹ️ Note: 2 adjustment rows processed (1 Credit, 1 Refund)
```

**Success Criteria**:
- [ ] Credits subtracted from total
- [ ] Refunds handled correctly
- [ ] Zero-cost rows not excluded
- [ ] Clear summary of adjustments

---

### POV-6: The 1 Million Row Stress Test

**Context**: Enterprise met 1M+ daily API calls. Calibrate moet schalen.

```bash
# Generate test data
python3 generate_scale_data.py --rows 1000000 --cardinality 500 --output actuals-1m.focus.csv

# Measure performance
echo "=== Scale Test: 1M Rows ==="
time llm-cost calibrate \
  --estimates estimates.json \
  --actuals actuals-1m.focus.csv \
  --max-memory 512MB \
  --format json > /dev/null

# Expected:
# real    0m18.234s  (< 30 seconds)
# user    0m16.891s
# sys     0m1.343s
# Peak memory: 387MB (< 512MB limit)
```

**Success Criteria**:
- [ ] 1M rows in <30 seconds
- [ ] Memory under configured limit
- [ ] Correct aggregation despite volume
- [ ] No OOM kill

---

### POV-7: Unicode, Spaces, and Special Characters

**Context**: International teams gebruiken non-ASCII prompt names.

```bash
cat > estimates-international.json << 'EOF'
{"prompts": [
  {"resource_id": "übersetzung-deutsch", "cost_usd": 25.00},
  {"resource_id": "翻译-中文", "cost_usd": 30.00},
  {"resource_id": "prompt with spaces", "cost_usd": 15.00},
  {"resource_id": "path/with/slashes", "cost_usd": 20.00},
  {"resource_id": "quote\"test", "cost_usd": 10.00}
]}
EOF

cat > actuals-international.focus.csv << 'EOF'
ChargePeriodStart,ChargePeriodEnd,ResourceId,BilledCost,ChargeCategory
2025-01-01,2025-01-31,übersetzung-deutsch,27.00,Usage
2025-01-01,2025-01-31,翻译-中文,33.00,Usage
2025-01-01,2025-01-31,prompt with spaces,16.00,Usage
2025-01-01,2025-01-31,path/with/slashes,22.00,Usage
2025-01-01,2025-01-31,"quote""test",11.00,Usage
EOF

llm-cost calibrate --estimates estimates-international.json --actuals actuals-international.focus.csv

# Expected: 100% match rate, correct drift calculation
```

**Success Criteria**:
- [ ] UTF-8 characters preserved
- [ ] Spaces in IDs handled
- [ ] Slashes don't break parsing
- [ ] Quotes properly escaped
- [ ] Deterministic regardless of locale

---

## Tier 3: Integration Validation

*Doel: Bewijs interoperabiliteit met FinOps ecosystem*

### POV-8: Vantage Round-Trip Test

**Context**: Validate volledige flow: llm-cost → Vantage → Vantage export → llm-cost calibrate

```bash
# Step 1: Export from llm-cost
llm-cost export --manifest llm-cost.toml --format focus > llm-cost-export.csv

# Step 2: Upload to Vantage (manual via UI)
# - Go to Custom Providers
# - Create "llm-cost" provider
# - Upload CSV

# Step 3: Wait for processing (~5 minutes)

# Step 4: Export from Vantage
# - Cost Reports → Export → FOCUS CSV
# - Save as vantage-export.csv

# Step 5: Calibrate against Vantage round-trip
llm-cost calibrate \
  --estimates estimates.json \
  --actuals vantage-export.csv \
  --matching fuzzy

# Expected: Near-zero drift (same data source)
# Validates: Tags preserved, ResourceIds matchable
```

**Success Criteria**:
- [ ] Vantage accepts llm-cost CSV (pre-flight validation)
- [ ] Tags queryable in Vantage UI
- [ ] Export from Vantage parseable by llm-cost
- [ ] Round-trip drift <1% (floating point only)

---

### POV-9: GitHub Actions Integration

**Context**: Full CI/CD workflow met PR comments en budget gates

```yaml
# .github/workflows/llm-cost-gate.yml
name: LLM Cost Governance

on:
  pull_request:
    paths:
      - 'prompts/**'
      - 'llm-cost.toml'

jobs:
  cost-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Install llm-cost
        run: |
          curl -sSL https://get.llm-cost.dev | sh
          llm-cost --version
      
      - name: Estimate costs (current)
        run: |
          git checkout ${{ github.base_ref }}
          llm-cost estimate --manifest llm-cost.toml --format json > baseline.json
      
      - name: Estimate costs (PR)
        run: |
          git checkout ${{ github.head_ref }}
          llm-cost estimate --manifest llm-cost.toml --format json > proposed.json
      
      - name: Check budget gate
        id: budget
        run: |
          llm-cost check \
            --manifest llm-cost.toml \
            --baseline baseline.json \
            --fail-on-increase 50% \
            --format json > result.json
        continue-on-error: true
      
      - name: Comment on PR
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const result = JSON.parse(fs.readFileSync('result.json'));
            
            let body = '## 💰 LLM Cost Impact\n\n';
            body += `| Metric | Baseline | Proposed | Change |\n`;
            body += `|--------|----------|----------|--------|\n`;
            body += `| Monthly Cost | $${result.baseline_cost} | $${result.proposed_cost} | ${result.change_pct}% |\n`;
            
            if (result.blocked) {
              body += '\n⛔ **This PR is blocked due to cost increase exceeding threshold.**\n';
              body += `\nTo proceed, either reduce costs or add \`/cost-override\` to the PR description.`;
            }
            
            github.rest.issues.createComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
              body: body
            });
      
      - name: Enforce gate
        if: steps.budget.outcome == 'failure'
        run: exit 1
```

**Success Criteria**:
- [ ] Installs in CI in <10 seconds
- [ ] Baseline vs PR comparison works
- [ ] PR comment generated
- [ ] Exit code blocks merge when over budget

---

### POV-10: Multi-Provider Consolidation

**Context**: Team gebruikt OpenAI, Anthropic, en Google. Finance wil één view.

```bash
cat > llm-cost.toml << 'EOF'
[[prompts]]
id = "search"
model = "gpt-4o"
[prompts.tags]
provider = "openai"

[[prompts]]
id = "summarize"
model = "claude-3-5-sonnet"
[prompts.tags]
provider = "anthropic"

[[prompts]]
id = "translate"
model = "gemini-1.5-pro"
[prompts.tags]
provider = "google"
EOF

llm-cost export --manifest llm-cost.toml --format focus > multi-provider.csv

# Verify all providers in single FOCUS export
cat multi-provider.csv | grep -E "openai|anthropic|google"

# Expected: All three providers in unified format
# Can be uploaded to single Vantage Custom Provider
```

**Success Criteria**:
- [ ] All providers in single FOCUS CSV
- [ ] Provider info in Tags (not separate column, per Vantage constraint)
- [ ] Single import to FinOps platform
- [ ] Filterable by provider in dashboard

---

## Tier 4: Compliance & Audit

*Doel: Enterprise audit requirements*

### POV-11: Deterministic Output Guarantee

**Context**: Auditors require reproducible results. Same input = identical output, always.

```bash
# Run on Linux
docker run --rm -v $(pwd):/data ubuntu:24.04 bash -c "
  apt-get update && apt-get install -y curl
  curl -sSL https://get.llm-cost.dev | sh
  llm-cost calibrate \
    --estimates /data/estimates.json \
    --actuals /data/actuals.csv \
    --format json > /data/output-linux.json
"

# Run on macOS (native)
llm-cost calibrate \
  --estimates estimates.json \
  --actuals actuals.csv \
  --format json > output-macos.json

# Run on Windows (WSL)
wsl llm-cost calibrate \
  --estimates estimates.json \
  --actuals actuals.csv \
  --format json > output-windows.json

# Compare all three
sha256sum output-*.json
# Expected: Identical hashes

diff output-linux.json output-macos.json
# Expected: No differences
```

**Success Criteria**:
- [ ] Byte-identical output across Linux/macOS/Windows
- [ ] No floating-point variance
- [ ] Timestamps in UTC (not local time)
- [ ] Deterministic ordering of output fields

---

### POV-12: Audit Trail in factors.toml

**Context**: SOX compliance requires traceability of all cost calculations.

```bash
llm-cost calibrate \
  --estimates estimates.json \
  --actuals actuals.csv \
  --output factors.toml

# Verify audit metadata
cat factors.toml

# Expected metadata section:
# [metadata]
# generated_at = "2025-01-15T10:30:00Z"
# llm_cost_version = "1.2.0"
# estimates_file = "estimates.json"
# estimates_sha256 = "a1b2c3d4..."
# actuals_file = "actuals.csv"
# actuals_sha256 = "e5f6g7h8..."
# observation_period_start = "2025-01-01"
# observation_period_end = "2025-01-31"
# sample_size = 847
# method = "linear_multiplicative"
```

**Success Criteria**:
- [ ] Full input file lineage
- [ ] SHA256 hashes for reproducibility
- [ ] Tool version recorded
- [ ] ISO 8601 UTC timestamps
- [ ] Method documented

---

### POV-13: PII Handling (GDPR Compliance)

**Context**: Actuals CSV bevat user emails in ChargeDescription. Output mag geen PII bevatten.

```bash
cat > actuals-with-pii.focus.csv << 'EOF'
ChargePeriodStart,ChargePeriodEnd,ResourceId,BilledCost,ChargeCategory,ChargeDescription
2025-01-01,2025-01-31,search,100.00,Usage,"Query by john.doe@company.com: find product X"
2025-01-01,2025-01-31,summarize,50.00,Usage,"Request from jane.smith@company.com for article summary"
EOF

llm-cost calibrate \
  --estimates estimates.json \
  --actuals actuals-with-pii.focus.csv \
  --output factors.toml

# Verify NO PII in output
grep -iE "[a-z]+\.[a-z]+@" factors.toml
# Expected: No matches

grep -iE "john|jane|doe|smith" factors.toml
# Expected: No matches
```

**Success Criteria**:
- [ ] ChargeDescription not retained in output
- [ ] No email addresses in factors.toml
- [ ] No names in factors.toml
- [ ] Only structured fields (ResourceId, BilledCost) used

---

## Tier 5: Failure Mode Testing

*Doel: Graceful degradation, niet silent failures*

### POV-14: Empty and Missing Data

```bash
# Empty estimates
echo '{"prompts": []}' > empty-estimates.json
llm-cost calibrate --estimates empty-estimates.json --actuals actuals.csv
# Expected: Exit 3, "Error: No estimates to calibrate"

# Empty actuals
echo "ChargePeriodStart,ResourceId,BilledCost" > empty-actuals.csv
llm-cost calibrate --estimates estimates.json --actuals empty-actuals.csv
# Expected: Exit 3, "Error: No actuals data found (0 rows after header)"

# Missing required column
echo "ChargePeriodStart,ResourceId" > missing-column.csv
echo "2025-01-01,search" >> missing-column.csv
llm-cost calibrate --estimates estimates.json --actuals missing-column.csv
# Expected: Exit 2, "Error: Required column 'BilledCost' not found"
```

**Success Criteria**:
- [ ] Clear error messages
- [ ] Correct exit codes
- [ ] No stack traces in normal error cases

---

### POV-15: Extreme Drift Detection

**Context**: 1000x drift suggests data quality issue, not estimation error.

```bash
cat > estimates-tiny.json << 'EOF'
{"prompts": [{"resource_id": "search", "cost_usd": 1.00}]}
EOF

cat > actuals-huge.focus.csv << 'EOF'
ChargePeriodStart,ChargePeriodEnd,ResourceId,BilledCost,ChargeCategory
2025-01-01,2025-01-31,search,1000.00,Usage
EOF

llm-cost calibrate --estimates estimates-tiny.json --actuals actuals-huge.focus.csv

# Expected:
# ❌ EXTREME DRIFT DETECTED
#
# ResourceId: search
#   Estimated: $1.00
#   Actual:    $1,000.00
#   Drift:     +99,900% (1000x)
#
# ⚠️ This magnitude of drift typically indicates:
#   - Data quality issue (wrong ResourceId mapping)
#   - Missing cost components in estimates
#   - Currency mismatch
#
# Calibration factor NOT auto-applied.
# Use --force to override (not recommended).
```

**Success Criteria**:
- [ ] Extreme drift flagged
- [ ] Likely causes suggested
- [ ] Auto-apply blocked
- [ ] --force override available but discouraged

---

## Test Execution Matrix

| Test ID | Category | Priority | Automated | Manual | Stakeholder |
|---------|----------|----------|-----------|--------|-------------|
| POV-1 | Value | P0 | ✅ | | VP Eng, CFO |
| POV-2 | Value | P0 | ✅ | | Platform Lead |
| POV-3 | Value | P0 | ✅ | | Finance |
| POV-4 | Data Quality | P0 | ✅ | | Data Eng |
| POV-5 | Data Quality | P1 | ✅ | | FinOps |
| POV-6 | Scale | P1 | ✅ | | SRE |
| POV-7 | Data Quality | P1 | ✅ | | i18n Team |
| POV-8 | Integration | P0 | | ✅ | FinOps |
| POV-9 | Integration | P0 | ✅ | | DevOps |
| POV-10 | Integration | P1 | ✅ | | FinOps |
| POV-11 | Compliance | P0 | ✅ | | Audit |
| POV-12 | Compliance | P1 | ✅ | | Audit |
| POV-13 | Compliance | P1 | ✅ | | Legal |
| POV-14 | Failure | P0 | ✅ | | QA |
| POV-15 | Failure | P1 | ✅ | | QA |

---

## Success Metrics (FinOps Foundation 2025)

| Metric | Target | Source |
|--------|--------|--------|
| Estimate accuracy (post-calibration) | ≤5% variance | FinOps AI WG |
| Time to first value | <30 minutes | Industry benchmark |
| CI gate latency | <10 seconds | DevOps best practice |
| FOCUS compliance | 100% required fields | FOCUS 1.0 spec |
| Cross-platform determinism | 100% | Audit requirement |
| Memory efficiency (1M rows) | <500MB | Production constraint |

---

## Quick Start: Run All P0 Tests

```bash
#!/bin/bash
# run-p0-tests.sh

set -e

echo "=== llm-cost P0 Test Suite ==="

echo "[1/6] POV-1: Regression Detection..."
./tests/pov-1-regression.sh && echo "✅ PASS" || echo "❌ FAIL"

echo "[2/6] POV-2: Cache Drift Detection..."
./tests/pov-2-cache-drift.sh && echo "✅ PASS" || echo "❌ FAIL"

echo "[3/6] POV-3: Chargeback Report..."
./tests/pov-3-chargeback.sh && echo "✅ PASS" || echo "❌ FAIL"

echo "[4/6] POV-4: Fuzzy Matching..."
./tests/pov-4-fuzzy-match.sh && echo "✅ PASS" || echo "❌ FAIL"

echo "[5/6] POV-11: Determinism..."
./tests/pov-11-determinism.sh && echo "✅ PASS" || echo "❌ FAIL"

echo "[6/6] POV-14: Error Handling..."
./tests/pov-14-errors.sh && echo "✅ PASS" || echo "❌ FAIL"

echo ""
echo "=== P0 Suite Complete ==="
```

---

## Appendix: 2025 FinOps Best Practices Applied

| Best Practice | How llm-cost Implements |
|---------------|-------------------------|
| **Unit Economics** | Per-prompt cost attribution |
| **Shift-Left** | CI/CD integration, PR gates |
| **Data-Driven Decisions** | Calibration loop with actuals |
| **Standardization** | FOCUS 1.0 export |
| **Automation** | factors.toml auto-generated |
| **Auditability** | SHA256 lineage, deterministic output |
| **Privacy by Design** | PII stripping, local-only execution |
