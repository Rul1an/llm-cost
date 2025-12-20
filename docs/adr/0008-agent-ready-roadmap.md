# ADR-008: Agent-Ready Roadmap (v1.10 → v1.12)

**Status**: Accepted
**Date**: 2025-12-20
**Deciders**: Roel, Claude
**Supersedes**: N/A

---

## Context

AI agent frameworks (LangGraph, CrewAI, AutoGen, Mastra) generate multi-model, multi-agent cost attribution challenges.
`llm-cost` v1.9.x lacks per-agent breakdown, governance gates, and CI-native OTel ingestion.

**Core Principle**: Build on **conventions** (FOCUS tags, OTel GenAI Semantic Conventions), not specific framework plugins.

---

## Decision

### Roadmap Structure

- **v1.10.0 "DX Polish"**: Global flags, minimal init (Completed)
- **v1.11.0 "Agent Breakdown"**: Tag Resolver, OTel Converter, Agentic Gates
- **v1.12.0 "CI Native"**: SARIF Output
- **v2.0.0**: Quality Routing (Future)

### D1: `--group-by` Flattened Breakdown

Support flat, comma-separated keys for calibration aggregation. No JSON nesting.

**Example**:
`llm-cost calibrate --group-by agent,tool`

**Output**:
```json
{
  "breakdown": {
    "by_agent": { "researcher": { "cost": 0.50 } },
    "by_tool": { "web_search": { "cost": 0.10 } },
    "by_key": { "agent=researcher|tool=web_search": { "cost": 0.10 } }
  }
}
```

Usage of `__other__` bucket for high-cardinality fields.

### D2: Tag Mapping & Defaults

Convention-based defaults with config override.

**Default Mappings**:
- `agent` -> `Tags.agent`
- `tool` -> `Tags.tool`
- `workflow` -> `Tags.workflow`
- `trace_id` -> `Tags.trace_id`
- `model` -> `ResourceId`

**OTel Integration (Implicit)**:
When converting OTel, map `gen_ai.tool.name` to `Tags.tool`.

### D3: Run Boundary

**Resolution**:
1. `Tags.trace_id` (OTel standard)
2. `Tags.workflow`
3. Fallback: Warn and skip run-scoped gates (Best Effort).

### D4: OTel Converter (JSON Only)

Subcommand: `llm-cost convert otel --input spans.json --output actuals.csv`
Format: OTel JSON (no protobuf dependency).

**OTel GenAI -> FOCUS Mapping**:

| OTel Attribute | FOCUS Column | Note |
| :--- | :--- | :--- |
| `gen_ai.request.model` | `ResourceId` | |
| `gen_ai.provider.name` | `Provider` | |
| `gen_ai.usage.input_tokens` | `x-token-count-input` | Preferred |
| `gen_ai.usage.output_tokens` | `x-token-count-output` | Preferred |
| `gen_ai.usage.prompt_tokens` | `x-token-count-input` | Fallback (Deprecated) |
| `gen_ai.usage.completion_tokens` | `x-token-count-output` | Fallback (Deprecated) |
| `gen_ai.tool.name` | `Tags.tool` | |
| `gen_ai.operation.name` | `Tags.operation` | Useful for `execute_tool` vs `chat` |
| `trace_id` (span root) | `Tags.trace_id` | |

**Privacy**:
Explicitly **IGNORE** `gen_ai.input.messages` and `gen_ai.output.messages`. Do not export payload content to CSV.

### D5: Implementation - Tag Resolver

New module `src/core/tag_resolver.zig` to handle `Tags.key` vs `ColumnName` resolution.

### D6: Agentic Governance

New config section: `[governance.agentic]`.

**Gates**:
- `max_cost_per_run` (Error, requires `run_id`)
- `max_tool_retries` (Error, proxy via `count(run_id, tool)`)
- `max_unknown_model_pct` (Warning)

### D7: SARIF Output (v1.12)

Generate SARIF 2.1.0 JSON. Use stable Rule IDs (e.g., `AGENT001`). No schema embedding in binary.

---

## Consequences

- **Zero-dep**: No protobuf or framework plugins required.
- **Privacy**: Content-safe by design (metadata only).
- **Scalability**: Flattened breakdown avoids combinatorial explosion in JSON output.
