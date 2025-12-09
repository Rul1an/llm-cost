# Roadmap: Fase 1.5 – OSS Technical Hardening

**Version:** 1.0  
**Status:** Draft  
**Author:** [Maintainer]  
**Date:** 2025-01  

---

## Executive Summary

Fase 1.5 brengt llm-cost van "nette OSS-tool" naar "technisch fundament voor enterprise automation". Geen nieuwe eindgebruiker-features; wel de architectuur, contracten en guarantees die nodig zijn voordat teams hierop durven te bouwen.

**Doorlooptijd:** 6-8 weken (solo developer)  
**Blocker voor:** Fase 2 (Internal/Enterprise Tool)

---

## Scope

### In Scope

| ID | Component | Beschrijving |
|----|-----------|--------------|
| R1 | BPE v2 | Lineair O(N) algoritme ter vervanging van O(N log N) heap-based |
| R2 | CLI Contract | JSON output, exit codes, quiet mode als stabiele API |
| R3 | Pricing v2 | Input/output split, eerlijke scope-afbakening |
| R4 | SLSA L2 | Provenance attestations, pinned actions, verificatie-docs |
| R5 | Legal/Vocab | NOTICE file, vocab traceability |
| R6 | Golden Tests | CLI contract tests naast parity tests |
| R7 | Backend Arch | Comptime generics voor tokenizer backends |

### Out of Scope (Fase 2+)

- SentencePiece backend implementatie
- C ABI / WASM builds
- Vendor usage log enrichment
- Multi-tenant features
- Pricing voor reasoning/cached/tool tokens

---

## Dependencies

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  R7 Backend Arch ◄─────┐                                    │
│        │               │                                    │
│        ▼               │                                    │
│  R1 BPE v2 ────────────┤                                    │
│        │               │                                    │
│        ▼               │                                    │
│  R6 Golden Tests ◄─────┴─── R2 CLI Contract                 │
│        │                          │                         │
│        │                          ▼                         │
│        │                    R3 Pricing v2                   │
│        │                          │                         │
│        ▼                          ▼                         │
│  ┌─────────────────────────────────────┐                    │
│  │         Release Gate                │                    │
│  │  (all tests green, docs complete)   │                    │
│  └─────────────────────────────────────┘                    │
│        │                                                    │
│        ▼                                                    │
│  R4 SLSA L2 ◄──── R5 Legal/Vocab                           │
│        │                                                    │
│        ▼                                                    │
│  ┌─────────────────────────────────────┐                    │
│  │      v0.5.0 Release                 │                    │
│  └─────────────────────────────────────┘                    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Critical Path:** R7 → R1 → R6 → Release

---

## Timeline

### Week 1-2: Foundation

| Task | Owner | Deliverable | Exit Criteria |
|------|-------|-------------|---------------|
| R7.1 Define Backend trait | - | `src/tokenizer/backend.zig` | Compiles, no functional change |
| R7.2 Refactor O200k/Cl100k | - | Existing backends use new trait | All tests pass |
| R7.3 Add HeuristicBackend | - | Char-based fallback via same interface | Heuristic mode works |
| R5.1 NOTICE file | - | `NOTICE` in repo root | Legal review pass |
| R5.2 docs/vocab.md | - | Vocab provenance documented | Links to source commits |

### Week 3-4: BPE v2

| Task | Owner | Deliverable | Exit Criteria |
|------|-------|-------------|---------------|
| R1.1 Research linear BPE | - | Internal doc with algorithm choice | Approach documented |
| R1.2 Implement bpe_linear.zig | - | New BPE engine | Compiles |
| R1.3 Parity validation | - | Evil Corpus passes | 100% parity |
| R1.4 Performance benchmark | - | `zig build bench-compare` | ≥2x speedup worst-case |
| R1.5 Switch default engine | - | Linear BPE is default | No regressions |

### Week 5-6: CLI Contract

| Task | Owner | Deliverable | Exit Criteria |
|------|-------|-------------|---------------|
| R2.1 JSON output mode | - | `--format json` flag | Valid JSON per line |
| R2.2 Summary JSON | - | `--summary-format json` | Schema documented |
| R2.3 Exit codes | - | `ExitCode` enum, mapped | Matches spec |
| R2.4 Quiet mode | - | `--quiet` flag | Only JSON output |
| R3.1 Pricing struct v2 | - | `CostBreakdown` with split | Tests pass |
| R3.2 Pricing docs | - | Scope statement in docs | Review approved |

### Week 7: Testing & Hardening

| Task | Owner | Deliverable | Exit Criteria |
|------|-------|-------------|---------------|
| R6.1 Golden test fixtures | - | `testdata/golden/*` | 3+ test sets |
| R6.2 Golden test runner | - | `zig build test-golden` | In CI |
| R6.3 Exit code tests | - | Shell-based CI tests | All codes tested |
| R2.5 CLI docs | - | `docs/cli.md` complete | Schema + codes documented |

### Week 8: Release Prep

| Task | Owner | Deliverable | Exit Criteria |
|------|-------|-------------|---------------|
| R4.1 Pin all actions | - | SHA-pinned workflows | No tag refs |
| R4.2 SLSA provenance | - | `.intoto.jsonl` generation | Verifier passes |
| R4.3 Security docs | - | `docs/security.md` update | SLSA L2 claim explicit |
| R4.4 Release v0.5.0 | - | Tagged release | All artifacts signed |

---

## Milestones

| Milestone | Target | Gate Criteria |
|-----------|--------|---------------|
| M1: Backend Arch | Week 2 | R7 complete, tests green |
| M2: BPE v2 | Week 4 | R1 complete, parity + perf validated |
| M3: CLI Contract | Week 6 | R2 + R3 complete, JSON output stable |
| M4: Test Suite | Week 7 | R6 complete, golden tests in CI |
| M5: Release | Week 8 | R4 + R5 complete, v0.5.0 shipped |

---

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Linear BPE breaks parity | Medium | High | Extensive Evil Corpus testing; keep v1 as fallback |
| SLSA generator incompatible | Low | Medium | Generic workflow supports any artifact type |
| Scope creep (new features) | Medium | Medium | Hard freeze on feature requests until M5 |
| Performance regression | Low | High | Automated bench in CI; alert on >10% regression |

---

## Success Criteria

Fase 1.5 is complete wanneer:

1. **Performance:** `zig build bench-bpe` toont O(N) scaling
2. **Correctness:** `zig build test-parity` 100% groen
3. **Contract:** `zig build test-golden` 100% groen
4. **Security:** `slsa-verifier` valideert release artifacts
5. **Legal:** NOTICE file present, vocab.md complete
6. **Docs:** architecture.md, cli.md, security.md up-to-date

---

## Post-Fase 1.5

Met deze basis kun je naar Fase 2:

- Internal deployment playbooks
- Load testing (10GB+ workloads)
- FinOps dashboard integration
- Vendor log enrichment tools

De architectuur ondersteunt dan ook Fase 3 (multi-provider, SentencePiece, etc.) zonder breaking changes.
