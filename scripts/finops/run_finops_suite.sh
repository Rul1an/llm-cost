#!/usr/bin/env bash
set -euo pipefail

SUITE="${1:-p0}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${ROOT}/zig-out/bin/llm-cost"
DATA="${ROOT}/testdata/finops"
REPORT_DIR="${ROOT}/reports"
mkdir -p "${REPORT_DIR}"

export TZ=UTC
export LC_ALL=C
# Ensure deterministic metadata if supported, or just for environment consistency
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1734134400}" # 2025-12-14T00:00:00Z

fail() { echo "❌ $*" >&2; exit 1; }
ok() { echo "✅ $*"; }

build_bin() {
  local ZIG_BIN="zig"
  if [ -x "${HOME}/.zvm/bin/zig" ]; then
    ZIG_BIN="${HOME}/.zvm/bin/zig"
  fi

  (cd "${ROOT}" && "${ZIG_BIN}" build -Doptimize=ReleaseFast)
  test -x "${BIN}" || fail "Binary not found at ${BIN}"
}

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}';
  else shasum -a 256 "$1" | awk '{print $1}';
  fi
}

assert_contains() {
  local hay="$1"; local needle="$2"
  echo "${hay}" | grep -Fq "${needle}" || fail "Expected output to contain: ${needle}"
}

assert_not_contains() {
  local hay="$1"; local needle="$2"
  echo "${hay}" | grep -Fq "${needle}" && fail "Expected output NOT to contain: ${needle}"
}

# -----------------------
# P0 tests (PR Gate)
# -----------------------
run_det_smoke() {
  local est="${DATA}/small/estimates.json"
  local act="${DATA}/small/actuals.clean.focus.csv"

  local out1="${REPORT_DIR}/p0_det_1.toml"
  local out2="${REPORT_DIR}/p0_det_2.toml"

  "${BIN}" calibrate --estimates "${est}" --actuals "${act}" > "${out1}"
  "${BIN}" calibrate --estimates "${est}" --actuals "${act}" > "${out2}"

  local h1 h2
  h1="$(sha256 "${out1}")"
  h2="$(sha256 "${out2}")"
  [[ "${h1}" = "${h2}" ]] || fail "Determinism failed: ${h1} != ${h2}"
  ok "Determinism: factors.toml byte-identical"
}

run_schema_missing_col() {
  local est="${DATA}/small/estimates.json"
  local act="${DATA}/small/actuals.missing_billedcost.focus.csv"
  set +e
  out="$("${BIN}" calibrate --estimates "${est}" --actuals "${act}" 2>&1)"
  code=$?
  set -e
  [[ $code -ne 0 ]] || fail "Expected non-zero exit for missing column"
  assert_contains "${out}" "BilledCost"
  ok "Missing columns: hard error + message"
}

run_fuzzy_match() {
  local est="${DATA}/small/estimates.json"
  local act="${DATA}/small/actuals.fuzzy.focus.csv"
  out="$("${BIN}" calibrate --match fuzzy --estimates "${est}" --actuals "${act}" 2>&1)"
  echo "${out}" > "${REPORT_DIR}/p0_fuzzy_stdout.txt"
  ok "Fuzzy match: ran"
}

run_credits_negative() {
  local est="${DATA}/small/estimates.json"
  local act="${DATA}/small/actuals.credits.focus.csv"
  out="$("${BIN}" calibrate --estimates "${est}" --actuals "${act}" 2>&1)"
  echo "${out}" > "${REPORT_DIR}/p0_credits_stdout.txt"
  ok "Credits/negative: ran"
}

run_pii_guard() {
  local est="${DATA}/small/estimates.json"
  local act="${DATA}/small/actuals.with_pii.focus.csv"
  out="$("${BIN}" calibrate --estimates "${est}" --actuals "${act}")"
  echo "${out}" > "${REPORT_DIR}/p0_pii.toml"
  if grep -i -q "john\.doe@" "${REPORT_DIR}/p0_pii.toml"; then
    fail "PII leaked into output"
  fi
  ok "PII guard: no leakage"
}

run_validate_only() {
  local est="${DATA}/small/estimates.json"
  local act="${DATA}/small/actuals.clean.focus.csv"
  set +e
  out="$("${BIN}" calibrate --validate-only --estimates "${est}" --actuals "${act}" 2>&1)"
  code=$?
  set -e
  [[ $code -eq 0 ]] || fail "--validate-only expected exit 0, got ${code}"
  echo "${out}" > "${REPORT_DIR}/p0_validate_only.txt"
  ok "Validate-only: ready"
}

# -----------------------
# P1 tests (Main Branch)
# -----------------------

# 2.3 Unicode + specials: UTF-8, spaties, slashes
run_unicode_resource_ids() {
  local est="${DATA}/p1/estimates.unicode.json"
  local act="${DATA}/p1/actuals.unicode.focus.csv"
  out="$("${BIN}" calibrate --estimates "${est}" --actuals "${act}" 2>&1)"
  echo "${out}" > "${REPORT_DIR}/p1_unicode.toml"
  # Check minimal crash resistance + Unicode preservation
  assert_contains "$(cat "${REPORT_DIR}/p1_unicode.toml")" "übersetzung-de"
  assert_contains "$(cat "${REPORT_DIR}/p1_unicode.toml")" "翻译-zh"
  ok "Unicode ResourceIds: ok"
}

# 2.4 Duplicate ResourceIds in actuals: aggregation logic
run_duplicate_actuals_aggregation() {
  local est="${DATA}/p1/estimates.dup_actuals.json"
  local act="${DATA}/p1/actuals.dup_actuals.focus.csv"
  out="$("${BIN}" calibrate --estimates "${est}" --actuals "${act}" 2>&1)"
  echo "${out}" > "${REPORT_DIR}/p1_dup_actuals.toml"
  assert_contains "$(cat "${REPORT_DIR}/p1_dup_actuals.toml")" "search-query"
  ok "Duplicate actual rows aggregated: ok"
}

# 2.2 Missing x-* columns: degrade gracefully
run_missing_extensions_degrade() {
  local est="${DATA}/small/estimates.json"
  local act="${DATA}/p1/actuals.missing_x.focus.csv"
  out="$("${BIN}" calibrate --estimates "${est}" --actuals "${act}" 2>&1)"
  echo "${out}" > "${REPORT_DIR}/p1_missing_x.toml"
  ok "Missing x-* columns: ran (degrade)"
}

# 2.6 Malformed row behaviour: fail-fast
run_malformed_csv_row() {
  local est="${DATA}/small/estimates.json"
  local act="${DATA}/p1/actuals.corrupt_row.focus.csv"
  set +e
  out="$("${BIN}" calibrate --estimates "${est}" --actuals "${act}" 2>&1)"
  code=$?
  set -e
  [[ $code -ne 0 ]] || fail "Expected non-zero exit on corrupt CSV row (fail-fast mode)"
  assert_contains "${out}" "InvalidCost"
  ok "Corrupt row: hard error (fail-fast) ok"
}

# 3.2 High cardinality / max_groups guardrail
run_high_cardinality_guard() {
  local est="${DATA}/small/estimates.json"
  local act="${DATA}/p1/actuals.high_cardinality.focus.csv"
  set +e
  out="$("${BIN}" calibrate --max-groups 1000 --estimates "${est}" --actuals "${act}" 2>&1)"
  code=$?
  set -e
  [[ $code -ne 0 ]] || fail "Expected non-zero exit when max_groups exceeded"
  echo "${out}" | grep -iq "groups" || fail "Expected output to contain 'groups' (case-insensitive)"
  ok "High cardinality guard: triggered"
}

# 6.3 Extreme drift guardrail
run_extreme_drift_signal() {
  local est="${DATA}/p1/estimates.extreme_drift.json"
  local act="${DATA}/p1/actuals.extreme_drift.focus.csv"
  out="$("${BIN}" calibrate --estimates "${est}" --actuals "${act}" 2>&1)"
  echo "${out}" > "${REPORT_DIR}/p1_extreme_drift.toml"

  assert_contains "$(cat "${REPORT_DIR}/p1_extreme_drift.toml")" "multiplier"
  ok "Extreme drift: produces output (guardrail may be added later)"
}

run_p0() {
  { time {
    run_det_smoke
    run_schema_missing_col
    # run_fuzzy_match         # Feature removed in v1.8 (Strict Focus)
    # run_credits_negative    # Metadata not propagated yet
    run_pii_guard
    # run_validate_only       # Feature removed (merged into calibrate)
  }; } 2> "${REPORT_DIR}/perf_metrics.txt"
}

run_p1() {
  run_p0
  run_unicode_resource_ids
  run_duplicate_actuals_aggregation
  run_missing_extensions_degrade
  run_malformed_csv_row
  run_high_cardinality_guard
  run_extreme_drift_signal
}

main() {
  build_bin
  case "${SUITE}" in
    p0) run_p0 ;;
    p1) run_p1 ;;
    *) fail "Unknown suite: ${SUITE}" ;;
  esac
  ok "FinOps suite '${SUITE}' complete"
}

main
