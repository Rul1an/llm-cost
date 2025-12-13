# FOCUS Export

`llm-cost` supports exporting cost data in the **FinOps Open Cost & Usage Specification (FOCUS) 1.0** format. This allows integration with FinOps platforms like Vantage, CloudZero, and Kubecost.

## Command

```bash
llm-cost export --format focus -o costs.csv
```

## Columns & Mapping

The export produces a standard CSV compliant with FOCUS 1.0 Schema.

| FOCUS Column | Value / Source |
|--------------|----------------|
| `ResourceId` | Derived SHA256 of Prompt ID + Path |
| `ResourceName` | File path (e.g., `prompts/search.txt`) |
| `BilledCost` | Calculated Cost (USD) |
| `ChargePeriodStart` | Date of run (or `--test-date`) |
| `ServiceName` | `LLM Inference` |
| `ServiceCategory` | `AI and Machine Learning` |
| `ConsumedQuantity` | Total Tokens (Input + Output) |
| `ConsumedUnit` | `Tokens` |
| `Tags` | JSON dictionary of metadata (see below) |

### Tag Metadata

The `Tags` column includes:
*   `provider`: e.g., `openai`, `anthropic`
*   `model`: e.g., `gpt-4o`
*   `token_count_input`: Input tokens
*   `token_count_output`: Output tokens (estimated/static)
*   `cache_hit_ratio`: If `--cache-hit-ratio` was applied
*   `user_tags`: Any custom tags defined in `llm-cost.toml`

## Examples

**Basic Export**
```bash
llm-cost export -o daily_costs.csv
```

**Scenario Analysis (Cache Impact)**
Simulate a 50% cache hit ratio and export for analysis:
```bash
llm-cost export --cache-hit-ratio 0.5 -o projected_costs.csv
```

## Integration

Upload `costs.csv` to your FinOps provider's "Custom Cost" or "Generic CSV" ingestion endpoint.
