# llm-cost v1.2.0 Test Plan: FinOps Validation Suite

**Version**: 1.0  
**Date**: 2025-12-14  
**Author**: FinOps Data Engineering  
**Scope**: End-to-end validation of calibration loop + FOCUS integration

---

## Executive Summary

Dit testplan valideert dat `llm-cost` daadwerkelijk waarde levert voor FinOps teams. We testen niet alleen "werkt de code" maar "lost dit echte problemen op die we vandaag hebben".

### Test Categorieën

| Categorie | Doel | Prioriteit |
|-----------|------|------------|
| **Value Proof** | Bewijs ROI voor stakeholders | P0 |
| **Data Quality** | Handle messy real-world data | P0 |
| **Scale** | Production-grade performance | P1 |
| **Integration** | Works with FinOps ecosystem | P1 |
| **Edge Cases** | Graceful degradation | P2 |
| **Compliance** | Audit trail & determinism | P1 |

---

## Category 1: Value Proof Scenarios

*Doel: Demonstreer onmiddellijke waarde aan Finance/Engineering leadership*

### Test 1.1: Bill Shock Prevention

**Scenario**: Engineering team pusht een prompt change die 10x meer tokens gebruikt. Zonder governance wordt dit pas zichtbaar op de maandelijkse bill.

```bash
# Setup: Baseline prompt
echo "Summarize this article in 2 sentences." > prompt-v1.txt
llm-cost estimate prompt-v1.txt --model gpt-4o
# Expected: ~$0.003 per call

# Change: Verbose prompt (10x tokens)
cat > prompt-v2.txt << 'EOF'
You are an expert summarizer. Please read the following article carefully.
Consider the main themes, supporting arguments, key statistics, and conclusions.
Then provide a comprehensive summary that captures:
1. The main thesis
2. Three supporting points
3. Any counterarguments presented
4. The author's conclusion
5. Your assessment of the argument's strength

Article: {content}

Please structure your response with clear headers and bullet points.
EOF

llm-cost estimate prompt-v2.txt --model gpt-4o
# Expected: ~$0.03 per call (10x increase)

# CI Gate
llm-cost check --manifest llm-cost.toml --fail-on-increase 50%
# Expected: EXIT 1 (blocked)
```

**Success Criteria**:
- [ ] Cost increase detected before merge
- [ ] Clear error message with % increase
- [ ] Actionable: shows which prompt caused increase

**Value Statement**: "Caught $50K/month cost increase before it hit production"

---

### Test 1.2: Cache Misconfiguration Detection

**Scenario**: Team assumes 80% cache hit rate, reality is 25%. Monthly bill is 3x higher than forecast.

```bash
# Estimates with assumed 80% cache
llm-cost export --manifest llm-cost.toml --cache-hit-ratio 0.80 > estimates.json

# Actuals from production (simulated)
cat > actuals.focus.csv << 'EOF'
ChargePeriodStart,ChargePeriodEnd,ResourceId,BilledCost,ChargeCategory,Tags
2025-01-01,2025-01-31,search-query,450.00,Usage,"{""x-cache-hit-ratio"":""0.25""}"
2025-01-01,2025-01-31,summarize,280.00,Usage,"{""x-cache-hit-ratio"":""0.22""}"
EOF

# Calibrate
llm-cost calibrate --estimates estimates.json --actuals actuals.focus.csv

# Expected output:
# ⚠️ cache_hit_ratio drift: assumed 80%, actual 25% (-55pp)
# Recommendation: Update cache_hit_ratio to 0.25
# Impact: Estimates were $243, actuals $730 (+200%)
```

**Success Criteria**:
- [ ] Drift detected with correct magnitude
- [ ] Root cause identified (cache, not traffic)
- [ ] Actionable recommendation provided

**Value Statement**: "Identified cache misconfiguration causing 3x budget overrun"

---

### Test 1.3: Model Cost Comparison for Procurement

**Scenario**: Finance needs to decide between OpenAI and Anthropic for a new project. Need apples-to-apples comparison.

```bash
# Same prompt, different models
llm-cost estimate prompt.txt --model gpt-4o --format json > openai.json
llm-cost estimate prompt.txt --model claude-3-5-sonnet --format json > anthropic.json

# Export FOCUS for both
llm-cost export --model gpt-4o --calls-per-month 100000 --format focus > openai.focus.csv
llm-cost export --model claude-3-5-sonnet --calls-per-month 100000 --format focus > anthropic.focus.csv

# Compare
# Expected: Side-by-side cost at same volume
```

**Success Criteria**:
- [ ] Comparable FOCUS output for both providers
- [ ] Cost per 1M tokens clearly shown
- [ ] Can import both into Vantage for unified view

**Value Statement**: "Data-driven vendor selection saved 15% on annual contract"

---

### Test 1.4: Chargeback Report Generation

**Scenario**: Platform team needs to bill back AI costs to product teams based on usage.

```bash
# Manifest with team tags
cat > llm-cost.toml << 'EOF'
[[prompts]]
id = "search"
path = "prompts/search.txt"
model = "gpt-4o"
[prompts.tags]
team = "discovery"
cost_center = "CC-1001"

[[prompts]]
id = "recommendations"
path = "prompts/recs.txt"  
model = "gpt-4o"
[prompts.tags]
team = "personalization"
cost_center = "CC-1002"
EOF

# Export with tags
llm-cost export --manifest llm-cost.toml --format focus > chargeback.csv

# Verify tags survive for grouping
# Expected: Tags.team and Tags.cost_center present and filterable
```

**Success Criteria**:
- [ ] Cost attribution by team/cost_center
- [ ] FOCUS format importable to finance systems
- [ ] Aggregation matches total spend

**Value Statement**: "Automated monthly chargeback reports, saved 8 hours/month manual work"

---

## Category 2: Data Quality Edge Cases

*Doel: Handle real-world messy data without crashing*

### Test 2.1: ResourceId Mismatch (Fuzzy Matching)

**Scenario**: Vantage prefixes ResourceIds with provider name.

```bash
# Estimates use clean IDs
cat > estimates.json << 'EOF'
{
  "prompts": [
    {"resource_id": "search-query", "cost_usd": 100.00},
    {"resource_id": "summarize", "cost_usd": 50.00}
  ]
}
EOF

# Actuals have prefixed IDs (Vantage behavior)
cat > actuals.focus.csv << 'EOF'
ChargePeriodStart,ChargePeriodEnd,ResourceId,BilledCost,ChargeCategory
2025-01-01,2025-01-31,custom-llmcost/search-query,112.00,Usage
2025-01-01,2025-01-31,custom-llmcost/summarize,58.00,Usage
EOF

# Calibrate with fuzzy matching
llm-cost calibrate \
  --estimates estimates.json \
  --actuals actuals.focus.csv \
  --matching fuzzy

# Expected: 100% match rate despite prefix difference
```

**Success Criteria**:
- [ ] Fuzzy matching strips known prefixes
- [ ] Match rate reported correctly
- [ ] Unmatched IDs logged for debugging

---

### Test 2.2: Missing Extension Columns

**Scenario**: FinOps tool strips x-* columns during import/export cycle.

```bash
# Actuals without x-cache-hit-ratio (stripped by CloudHealth)
cat > actuals-stripped.focus.csv << 'EOF'
ChargePeriodStart,ChargePeriodEnd,ResourceId,BilledCost,ChargeCategory,Tags
2025-01-01,2025-01-31,search-query,150.00,Usage,"{""team"":""platform""}"
EOF

# Calibrate should still work, with reduced confidence
llm-cost calibrate \
  --estimates estimates.json \
  --actuals actuals-stripped.focus.csv

# Expected:
# ⚠️ x-cache-hit-ratio not present in actuals
# Cache drift cannot be directly measured
# Indirect estimation: BilledCost/ListCost suggests ~30% cache hit
# Confidence: LOW
```

**Success Criteria**:
- [ ] Graceful degradation, not crash
- [ ] Clear warning about missing data
- [ ] Indirect estimation attempted with LOW confidence tag

---

### Test 2.3: Unicode and Special Characters in ResourceId

**Scenario**: International team uses non-ASCII characters in prompt names.

```bash
# Estimates with unicode
cat > estimates.json << 'EOF'
{
  "prompts": [
    {"resource_id": "übersetzung-de", "cost_usd": 25.00},
    {"resource_id": "翻译-zh", "cost_usd": 30.00},
    {"resource_id": "prompt with spaces", "cost_usd": 15.00},
    {"resource_id": "prompt/with/slashes", "cost_usd": 20.00}
  ]
}
EOF

# Matching actuals
cat > actuals.focus.csv << 'EOF'
ChargePeriodStart,ChargePeriodEnd,ResourceId,BilledCost,ChargeCategory
2025-01-01,2025-01-31,übersetzung-de,27.00,Usage
2025-01-01,2025-01-31,翻译-zh,33.00,Usage
2025-01-01,2025-01-31,prompt with spaces,16.00,Usage
2025-01-01,2025-01-31,prompt/with/slashes,22.00,Usage
EOF

llm-cost calibrate --estimates estimates.json --actuals actuals.focus.csv
```

**Success Criteria**:
- [ ] UTF-8 handled correctly
- [ ] Spaces preserved in matching
- [ ] Slashes don't break parsing
- [ ] Deterministic output regardless of locale

---

### Test 2.4: Duplicate ResourceIds in Actuals

**Scenario**: Daily billing exports have multiple rows per ResourceId (one per day).

```bash
# 7 days of actuals for same ResourceId
cat > actuals-daily.focus.csv << 'EOF'
ChargePeriodStart,ChargePeriodEnd,ResourceId,BilledCost,ChargeCategory
2025-01-01,2025-01-01,search-query,15.00,Usage
2025-01-02,2025-01-02,search-query,18.00,Usage
2025-01-03,2025-01-03,search-query,12.00,Usage
2025-01-04,2025-01-04,search-query,22.00,Usage
2025-01-05,2025-01-05,search-query,14.00,Usage
2025-01-06,2025-01-06,search-query,8.00,Usage
2025-01-07,2025-01-07,search-query,11.00,Usage
EOF

# Calibrate should aggregate
llm-cost calibrate --estimates estimates.json --actuals actuals-daily.focus.csv

# Expected:
# ResourceId: search-query
# Actual (sum): $100.00
# Days: 7
# Avg/day: $14.29
```

**Success Criteria**:
- [ ] Correctly aggregates multiple rows per ResourceId
- [ ] Reports observation count
- [ ] Time range correctly identified

---

### Test 2.5: Zero-Cost and Negative-Cost Rows

**Scenario**: Billing data contains credits, refunds, or free tier usage.

```bash
cat > actuals-with-credits.focus.csv << 'EOF'
ChargePeriodStart,ChargePeriodEnd,ResourceId,BilledCost,ChargeCategory
2025-01-01,2025-01-31,search-query,100.00,Usage
2025-01-01,2025-01-31,search-query,-15.00,Credit
2025-01-01,2025-01-31,free-tier-prompt,0.00,Usage
EOF

llm-cost calibrate --estimates estimates.json --actuals actuals-with-credits.focus.csv

# Expected:
# search-query net: $85.00 (Usage - Credit)
# free-tier-prompt: $0.00 (included but flagged)
# ⚠️ Negative BilledCost detected (credits) - net cost calculated
```

**Success Criteria**:
- [ ] Credits handled (subtract from total)
- [ ] Zero-cost rows not excluded
- [ ] Clear reporting of adjustments

---

### Test 2.6: Malformed CSV Input

**Scenario**: CSV has encoding issues, missing columns, or corrupt rows.

```bash
# Missing required column
cat > actuals-bad-schema.focus.csv << 'EOF'
ChargePeriodStart,ChargePeriodEnd,ResourceId,ChargeCategory
2025-01-01,2025-01-31,search-query,Usage
EOF

llm-cost calibrate --estimates estimates.json --actuals actuals-bad-schema.focus.csv
# Expected: EXIT 2 with clear error
# Error: Required column 'BilledCost' not found in actuals

# Corrupt row mid-file
cat > actuals-corrupt.focus.csv << 'EOF'
ChargePeriodStart,ChargePeriodEnd,ResourceId,BilledCost,ChargeCategory
2025-01-01,2025-01-31,search-query,100.00,Usage
this,is,not,valid
2025-01-01,2025-01-31,summarize,50.00,Usage
EOF

llm-cost calibrate --estimates estimates.json --actuals actuals-corrupt.focus.csv
# Expected: Skip bad row, log warning, continue
# ⚠️ Row 2: Parse error (skipped)
# Processed: 2/3 rows
```

**Success Criteria**:
- [ ] Missing required columns = clear error, exit 2
- [ ] Corrupt rows = warning + skip, continue processing
- [ ] Report of skipped rows

---

## Category 3: Scale Testing

*Doel: Validate production-grade performance*

### Test 3.1: High Volume Actuals (1M Rows)

**Scenario**: Enterprise with 1M daily API calls over 30 days.

```bash
# Generate 1M row test file
python3 << 'EOF'
import csv
import random

with open('actuals-1m.focus.csv', 'w', newline='') as f:
    writer = csv.writer(f)
    writer.writerow(['ChargePeriodStart','ChargePeriodEnd','ResourceId','BilledCost','ChargeCategory'])
    
    prompts = [f'prompt-{i}' for i in range(1000)]  # 1000 unique prompts
    
    for i in range(1_000_000):
        writer.writerow([
            '2025-01-01',
            '2025-01-31',
            random.choice(prompts),
            round(random.uniform(0.001, 0.1), 6),
            'Usage'
        ])
EOF

# Measure performance
time llm-cost calibrate \
  --estimates estimates.json \
  --actuals actuals-1m.focus.csv \
  --max-memory 512MB

# Expected: Complete in <30 seconds, <512MB memory
```

**Success Criteria**:
- [ ] 1M rows processed in <30 seconds
- [ ] Memory stays under configured limit
- [ ] No OOM kill
- [ ] Correct aggregation despite volume

---

### Test 3.2: High Cardinality ResourceIds

**Scenario**: Each request has unique ResourceId (anti-pattern, but happens).

```bash
# 100K unique ResourceIds
python3 << 'EOF'
import csv
import uuid

with open('actuals-high-cardinality.focus.csv', 'w', newline='') as f:
    writer = csv.writer(f)
    writer.writerow(['ChargePeriodStart','ChargePeriodEnd','ResourceId','BilledCost','ChargeCategory'])
    
    for i in range(100_000):
        writer.writerow([
            '2025-01-01',
            '2025-01-31',
            f'request-{uuid.uuid4()}',  # Unique per row
            0.01,
            'Usage'
        ])
EOF

llm-cost calibrate \
  --estimates estimates.json \
  --actuals actuals-high-cardinality.focus.csv \
  --max-groups 10000

# Expected:
# ⚠️ High cardinality detected: 100,000 unique ResourceIds
# ⚠️ max_groups (10,000) exceeded - aggregating by prefix
# Match rate: 0% (no matching estimates)
```

**Success Criteria**:
- [ ] Warning about high cardinality
- [ ] Graceful handling with max_groups limit
- [ ] Clear explanation of low match rate

---

### Test 3.3: Concurrent CI Runs

**Scenario**: Multiple CI jobs run calibrate simultaneously on shared filesystem.

```bash
# Simulate 10 concurrent runs
for i in {1..10}; do
  llm-cost calibrate \
    --estimates estimates.json \
    --actuals actuals.focus.csv \
    --output factors-$i.toml &
done
wait

# Verify all outputs identical (determinism)
md5sum factors-*.toml | awk '{print $1}' | sort -u | wc -l
# Expected: 1 (all identical)
```

**Success Criteria**:
- [ ] No file locking issues
- [ ] All outputs byte-identical
- [ ] No race conditions

---

## Category 4: Integration Testing

*Doel: Validate interoperability with FinOps ecosystem*

### Test 4.1: Vantage Round-Trip

**Scenario**: Export from llm-cost → Import to Vantage → Export from Vantage → Calibrate

```bash
# Step 1: Generate FOCUS export
llm-cost export --manifest llm-cost.toml --format focus > llm-cost-export.csv

# Step 2: Upload to Vantage Custom Provider
# (Manual step via UI or API)

# Step 3: Export from Vantage (after processing)
# Download as FOCUS CSV

# Step 4: Calibrate against Vantage export
llm-cost calibrate \
  --estimates estimates.json \
  --actuals vantage-export.focus.csv \
  --matching fuzzy  # Handle Vantage prefixes

# Expected: High match rate, low drift (it's the same data)
```

**Success Criteria**:
- [ ] Vantage accepts llm-cost FOCUS export
- [ ] Tags preserved through round-trip
- [ ] ResourceIds matchable (with fuzzy mode)
- [ ] Drift near zero (same data source)

---

### Test 4.2: Langfuse Integration

**Scenario**: Compare estimates against Langfuse observability data.

```bash
# Export from Langfuse (manual or API)
# Convert to FOCUS format
llm-cost import langfuse langfuse-export.json --output actuals.focus.csv

# Calibrate
llm-cost calibrate \
  --estimates estimates.json \
  --actuals actuals.focus.csv
```

**Success Criteria**:
- [ ] Langfuse JSON correctly converted to FOCUS
- [ ] Token counts preserved
- [ ] Cost calculations match Langfuse dashboard

---

### Test 4.3: GitHub Actions Integration

**Scenario**: Full CI/CD workflow with PR comments.

```yaml
# .github/workflows/llm-cost.yml
name: LLM Cost Gate
on: [pull_request]

jobs:
  cost-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Install llm-cost
        run: curl -sSL https://get.llm-cost.dev | sh
      
      - name: Estimate costs
        run: llm-cost estimate --manifest llm-cost.toml --format json > estimates.json
      
      - name: Check budget
        run: llm-cost check --manifest llm-cost.toml --budget 100.00
      
      - name: Comment on PR
        if: always()
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const estimates = JSON.parse(fs.readFileSync('estimates.json'));
            // Post comment with cost summary
```

**Success Criteria**:
- [ ] Installs in <10 seconds
- [ ] Check command blocks over-budget PRs
- [ ] Exit codes correct for CI interpretation
- [ ] PR comment generated successfully

---

## Category 5: Compliance & Audit

*Doel: Enterprise audit requirements*

### Test 5.1: Deterministic Output

**Scenario**: Same inputs must produce byte-identical outputs across platforms.

```bash
# Run on Linux
docker run --rm -v $(pwd):/data alpine sh -c "
  apk add llm-cost
  llm-cost calibrate --estimates /data/estimates.json --actuals /data/actuals.csv > /data/linux-output.json
"

# Run on macOS
llm-cost calibrate --estimates estimates.json --actuals actuals.csv > macos-output.json

# Compare
diff linux-output.json macos-output.json
# Expected: No difference
```

**Success Criteria**:
- [ ] Byte-identical output across Linux/macOS
- [ ] No floating-point variance
- [ ] Timestamps in UTC, not local time

---

### Test 5.2: Audit Trail in factors.toml

**Scenario**: Auditor needs to trace where calibration factors came from.

```bash
llm-cost calibrate \
  --estimates estimates.json \
  --actuals actuals.csv \
  --output factors.toml

cat factors.toml
# Expected:
# [metadata]
# generated_at = "2025-01-15T10:30:00Z"
# llm_cost_version = "1.2.0"
# estimates_file = "estimates.json"
# estimates_sha256 = "abc123..."
# actuals_file = "actuals.csv"
# actuals_sha256 = "def456..."
# sample_size = 847
# observation_period = "2025-01-01 to 2025-01-31"
```

**Success Criteria**:
- [ ] Full lineage in metadata
- [ ] SHA256 of input files
- [ ] Tool version recorded
- [ ] Timestamps in ISO 8601 UTC

---

### Test 5.3: GDPR/PII Handling

**Scenario**: Actuals file contains PII in ChargeDescription.

```bash
cat > actuals-with-pii.focus.csv << 'EOF'
ChargePeriodStart,ChargePeriodEnd,ResourceId,BilledCost,ChargeCategory,ChargeDescription
2025-01-01,2025-01-31,search-query,100.00,Usage,"Query from user john.doe@company.com about product X"
EOF

llm-cost calibrate \
  --estimates estimates.json \
  --actuals actuals-with-pii.focus.csv \
  --output factors.toml

# Verify PII not in output
grep -i "john.doe" factors.toml
# Expected: No match - ChargeDescription not retained
```

**Success Criteria**:
- [ ] ChargeDescription not stored in output
- [ ] Only structured fields (ResourceId, BilledCost, Tags) retained
- [ ] No PII leakage in logs or factors file

---

## Category 6: Negative Testing

*Doel: Verify graceful failure modes*

### Test 6.1: Empty Inputs

```bash
# Empty estimates
echo '{"prompts": []}' > empty-estimates.json
llm-cost calibrate --estimates empty-estimates.json --actuals actuals.csv
# Expected: EXIT 3 (INSUFFICIENT_DATA)
# Error: No estimates to calibrate

# Empty actuals
touch empty-actuals.csv
llm-cost calibrate --estimates estimates.json --actuals empty-actuals.csv
# Expected: EXIT 3
# Error: No actuals data found
```

---

### Test 6.2: Future Dates

```bash
cat > actuals-future.focus.csv << 'EOF'
ChargePeriodStart,ChargePeriodEnd,ResourceId,BilledCost,ChargeCategory
2030-01-01,2030-01-31,search-query,100.00,Usage
EOF

llm-cost calibrate --estimates estimates.json --actuals actuals-future.focus.csv
# Expected: Warning about future dates
# ⚠️ Actuals contain future dates (2030-01-01) - clock skew?
```

---

### Test 6.3: Extreme Drift Values

```bash
# Estimates say $1, actuals say $1000 (1000x drift)
cat > estimates-tiny.json << 'EOF'
{"prompts": [{"resource_id": "search", "cost_usd": 1.00}]}
EOF

cat > actuals-huge.focus.csv << 'EOF'
ChargePeriodStart,ChargePeriodEnd,ResourceId,BilledCost,ChargeCategory
2025-01-01,2025-01-31,search,1000.00,Usage
EOF

llm-cost calibrate --estimates estimates-tiny.json --actuals actuals-huge.focus.csv
# Expected:
# ❌ Extreme drift detected: +99900% (1000x)
# This likely indicates a data quality issue, not estimation error.
# Factor NOT auto-applied. Review data manually.
# Use --force to override.
```

---

## Test Execution Matrix

| Test ID | Scenario | Automated | Manual | Blocker |
|---------|----------|-----------|--------|---------|
| 1.1 | Bill Shock Prevention | ✅ | | P0 |
| 1.2 | Cache Misconfiguration | ✅ | | P0 |
| 1.3 | Model Comparison | ✅ | | P1 |
| 1.4 | Chargeback Reports | ✅ | | P1 |
| 2.1 | Fuzzy Matching | ✅ | | P0 |
| 2.2 | Missing x-* Columns | ✅ | | P1 |
| 2.3 | Unicode ResourceIds | ✅ | | P1 |
| 2.4 | Duplicate ResourceIds | ✅ | | P0 |
| 2.5 | Credits/Negatives | ✅ | | P1 |
| 2.6 | Malformed CSV | ✅ | | P0 |
| 3.1 | 1M Rows Scale | ✅ | | P1 |
| 3.2 | High Cardinality | ✅ | | P2 |
| 3.3 | Concurrent Runs | ✅ | | P1 |
| 4.1 | Vantage Round-Trip | | ✅ | P0 |
| 4.2 | Langfuse Integration | | ✅ | P2 |
| 4.3 | GitHub Actions | ✅ | | P0 |
| 5.1 | Determinism | ✅ | | P0 |
| 5.2 | Audit Trail | ✅ | | P1 |
| 5.3 | PII Handling | ✅ | | P1 |
| 6.1 | Empty Inputs | ✅ | | P0 |
| 6.2 | Future Dates | ✅ | | P2 |
| 6.3 | Extreme Drift | ✅ | | P1 |

---

## Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| All P0 tests pass | 100% | Automated |
| All P1 tests pass | 100% | Automated |
| Vantage round-trip validated | ✅ | Manual |
| 1M row performance | <30s | Benchmark |
| Cross-platform determinism | 100% | Docker + native |
| Zero PII in outputs | 100% | Grep scan |

---

## Demo Script for Stakeholders

```bash
#!/bin/bash
# demo.sh - 5-minute value demonstration

echo "=== llm-cost Value Demo ==="

echo ""
echo "1️⃣  Catching cost regression BEFORE merge..."
llm-cost check --manifest llm-cost.toml --fail-on-increase 20%
echo "   ✅ Would block PR with >20% cost increase"

echo ""
echo "2️⃣  Generating FOCUS export for FinOps dashboard..."
llm-cost export --manifest llm-cost.toml --format focus > costs.csv
echo "   ✅ $(wc -l < costs.csv) rows ready for Vantage import"

echo ""
echo "3️⃣  Calibrating estimates against actual billing..."
llm-cost calibrate --estimates estimates.json --actuals actuals.csv --dry-run
echo "   ✅ Drift analysis complete, recommendations generated"

echo ""
echo "=== Demo Complete ==="
echo "Time to first value: <5 minutes"
```

---

## Appendix: Test Data Files

All test data files are available in:
```
testdata/
├── estimates/
│   ├── basic.json
│   ├── multi-model.json
│   └── high-volume.json
├── actuals/
│   ├── clean.focus.csv
│   ├── with-credits.focus.csv
│   ├── vantage-export.focus.csv
│   ├── malformed.focus.csv
│   └── 1m-rows.focus.csv.gz
└── expected/
    ├── factors-basic.toml
    └── report-basic.md
```
