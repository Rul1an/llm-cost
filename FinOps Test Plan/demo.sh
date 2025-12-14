#!/bin/bash
# ============================================================================
# llm-cost Value Demo Script
# ============================================================================
# 
# Purpose: Demonstrate immediate value to Finance/Engineering leadership
# Runtime: ~2 minutes
# Requirements: llm-cost v1.2.0+, bash
#
# Usage: ./demo.sh [--quick]
# ============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTDATA_DIR="${SCRIPT_DIR}/testdata"

echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           llm-cost v1.2.0 Value Demonstration                  ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ============================================================================
# Demo 1: Cost Visibility
# ============================================================================
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Demo 1: Cost Visibility - Know Your Spend Before Deployment${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

echo -e "📊 ${GREEN}Scenario:${NC} You have 5 prompts in production. What do they cost?"
echo ""

# Simulate llm-cost estimate output
cat << 'EOF'
$ llm-cost estimate --manifest llm-cost.toml --format table

┌────────────────────┬─────────────────┬──────────────┬──────────────┐
│ Prompt             │ Model           │ Cost/Call    │ Monthly Est. │
├────────────────────┼─────────────────┼──────────────┼──────────────┤
│ search-query       │ gpt-4o          │ $0.0054      │ $53.75       │
│ summarize-article  │ gpt-4o          │ $0.0080      │ $40.00       │
│ classify-intent    │ gpt-4o-mini     │ $0.00003     │ $2.70        │
│ translate-content  │ claude-3-5-son  │ $0.0105      │ $84.00       │
│ code-review        │ claude-3-5-son  │ $0.0315      │ $63.00       │
├────────────────────┼─────────────────┼──────────────┼──────────────┤
│ TOTAL              │                 │              │ $243.45      │
└────────────────────┴─────────────────┴──────────────┴──────────────┘

By Team:
  discovery:  $53.75  (22%)
  content:    $40.00  (16%)
  platform:   $63.00  (26%)
  i18n:       $84.00  (35%)
  ml:         $2.70   (1%)
EOF

echo ""
echo -e "✅ ${GREEN}Value:${NC} Instant visibility into LLM spend by prompt, team, and model"
echo ""
sleep 2

# ============================================================================
# Demo 2: Regression Prevention
# ============================================================================
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Demo 2: Regression Prevention - Stop Cost Explosions${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

echo -e "🚨 ${GREEN}Scenario:${NC} Engineer adds verbose instructions to a prompt (10x tokens)"
echo ""

cat << 'EOF'
$ git diff prompts/search.txt
- Summarize this article in 2 sentences.
+ You are an expert summarizer with deep knowledge of journalism...
+ [50 more lines of instructions]
+ Please provide a comprehensive analysis including...

$ llm-cost check --manifest llm-cost.toml --fail-on-increase 50%

❌ COST REGRESSION DETECTED

  Prompt: search-query
  Before: $0.0054/call ($53.75/month)
  After:  $0.0540/call ($540.00/month)
  Change: +900% ⛔

  This PR would increase monthly costs by $486.25

  Options:
    1. Reduce prompt verbosity
    2. Switch to gpt-4o-mini (70% cheaper)
    3. Add justification and use --allow-increase

Exit code: 1 (BUDGET_EXCEEDED)
EOF

echo ""
echo -e "✅ ${GREEN}Value:${NC} Caught \$486/month regression BEFORE merge, not on next invoice"
echo ""
sleep 2

# ============================================================================
# Demo 3: Calibration
# ============================================================================
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Demo 3: Calibration - Close the Estimate/Actual Gap${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

echo -e "🔄 ${GREEN}Scenario:${NC} Monthly bill is 20% higher than estimates. Why?"
echo ""

cat << 'EOF'
$ llm-cost calibrate \
    --estimates estimates.json \
    --actuals billing-jan-2025.focus.csv

⚠️  Drift Analysis (January 2025)

  Estimated: $243.45
  Actual:    $293.70
  Drift:     +20.6% ($50.25)

┌─────────────────┬──────────┬──────────┬─────────┬────────────┐
│ Drift Source    │ Expected │ Actual   │ Impact  │ Confidence │
├─────────────────┼──────────┼──────────┼─────────┼────────────┤
│ Cache Hit Rate  │ 60%      │ 35%      │ +$38.00 │ HIGH       │
│ Output Tokens   │ baseline │ +15% avg │ +$12.00 │ MEDIUM     │
└─────────────────┴──────────┴──────────┴─────────┴────────────┘

Root Cause: Cache hit ratio assumed at 60%, but production shows 35%
            This is likely due to cache TTL < traffic pattern window

Recommendations:
  1. ✅ Update cache_hit_ratio to 0.35 in manifest (high confidence)
  2. 🔍 Review output tokens for code-review prompt (20% longer than expected)
  3. ⏳ Extend calibration period for classify-intent (low sample size)

Apply recommended changes? [y/N]
EOF

echo ""
echo -e "✅ ${GREEN}Value:${NC} Identified cache misconfiguration as root cause of \$50/month overrun"
echo ""
sleep 2

# ============================================================================
# Demo 4: FinOps Integration
# ============================================================================
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Demo 4: FinOps Integration - Unified Cost Dashboard${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

echo -e "📈 ${GREEN}Scenario:${NC} Finance needs LLM costs alongside cloud spend in Vantage"
echo ""

cat << 'EOF'
$ llm-cost export --manifest llm-cost.toml --format focus > llm-costs.csv

$ head -3 llm-costs.csv
ChargePeriodStart,ChargePeriodEnd,BilledCost,ResourceId,ServiceName,ChargeCategory,Tags
2025-01-01,2025-01-31,53.75,search-query,LLM Inference,Usage,{"team":"discovery"...}
2025-01-01,2025-01-31,40.00,summarize-article,LLM Inference,Usage,{"team":"content"...}

$ # Upload to Vantage Custom Provider
$ curl -X POST https://api.vantage.sh/v2/custom_providers/llm-cost/upload \
    -H "Authorization: Bearer $VANTAGE_API_KEY" \
    -F "file=@llm-costs.csv"

✓ Uploaded 5 cost records to Vantage
✓ Available in dashboard under "LLM Inference" service
EOF

echo ""
echo -e "✅ ${GREEN}Value:${NC} LLM costs visible in same dashboard as AWS/GCP spend"
echo "   - Filter by team for chargeback"
echo "   - Compare LLM vs cloud infrastructure trends"
echo "   - Single pane of glass for Finance"
echo ""
sleep 2

# ============================================================================
# Summary
# ============================================================================
echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                     Demo Summary                               ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

cat << 'EOF'
┌─────────────────────────────────────────────────────────────────────┐
│                    llm-cost Value Proposition                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  BEFORE llm-cost              AFTER llm-cost                        │
│  ─────────────────            ──────────────                        │
│  Cost visibility: Monthly     Cost visibility: Per-PR              │
│  Regression detection: 30d    Regression detection: <1 hour        │
│  Estimate accuracy: ±40%      Estimate accuracy: ±5% (calibrated)  │
│  Attribution: Service-level   Attribution: Prompt-level            │
│  FinOps integration: Manual   FinOps integration: FOCUS export     │
│                                                                     │
│  ────────────────────────────────────────────────────────────────   │
│                                                                     │
│  ROI Example (based on demo):                                       │
│    • Prevented regression: $486/month × 12 = $5,832/year           │
│    • Fixed cache config:   $50/month × 12 = $600/year              │
│    • Reduced manual work:  8 hrs/month × $100/hr = $9,600/year     │
│    ──────────────────────────────────────────────────────────────   │
│    Estimated Annual Savings: $16,032                                │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
EOF

echo ""
echo -e "${GREEN}Demo complete. Time to value: <5 minutes.${NC}"
echo ""
echo "Next steps:"
echo "  1. Install: curl -sSL https://get.llm-cost.dev | sh"
echo "  2. Init:    llm-cost init"
echo "  3. Export:  llm-cost export --format focus > costs.csv"
echo "  4. Import:  Upload to Vantage/CloudHealth"
echo ""
