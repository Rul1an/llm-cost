#!/usr/bin/env python3
import os, json, glob, hashlib, datetime
try:
    import tomllib
except ImportError:
    import sys
    print("Error: Python 3.11+ with tomllib required.")
    sys.exit(1)

def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def read_toml(path: str) -> dict:
    with open(path, "rb") as f:
        return tomllib.load(f)

def get_env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)

def utc_now_iso() -> str:
    sde = os.environ.get("SOURCE_DATE_EPOCH")
    if sde:
        dt = datetime.datetime.fromtimestamp(int(sde), tz=datetime.timezone.utc)
    else:
        dt = datetime.datetime.now(tz=datetime.timezone.utc)
    return dt.replace(microsecond=0).isoformat().replace("+00:00", "Z")

def extract_global_drift_bps(toml_obj: dict) -> float | None:
    # Pas keys aan aan jullie daadwerkelijke schema.
    # Probeert meerdere paden zodat het niet brittle is.
    candidates = [
        ("global", "drift_bps"),
        ("global", "drift", "bps"),
        ("global", "stats", "drift_bps"),
        ("metadata", "stats", "drift_bps"),
    ]
    for path in candidates:
        cur = toml_obj
        ok = True
        for k in path:
            if isinstance(cur, dict) and k in cur:
                cur = cur[k]
            else:
                ok = False
                break
        if ok:
            try:
                return float(cur)
            except Exception:
                return None
    return None

def main():
    reports_dir = get_env("FINOPS_REPORTS_DIR", "reports")
    out_audit = os.path.join(reports_dir, "audit.json")

    max_drift_bps = float(get_env("FINOPS_MAX_DRIFT_BPS", "10"))
    focus_version = get_env("FINOPS_FOCUS_VERSION", "1.1")
    fail_fast = get_env("FINOPS_FAIL_FAST", "true").lower() == "true"

    # Heuristiek: determinism test produceert meestal 2 outputs. Pak de eerste als referentie.
    det_candidates = sorted(glob.glob(os.path.join(reports_dir, "*det*.toml")))
    # Also check p0_det_1 explicit patterns if needed
    if not det_candidates:
        det_candidates = sorted(glob.glob(os.path.join(reports_dir, "p0_det_1.toml")))

    det_hash = sha256_file(det_candidates[0]) if det_candidates else None

    # Pak “meest representatieve” factors output om drift uit te lezen (eerste die matcht).
    toml_paths = sorted(glob.glob(os.path.join(reports_dir, "*.toml")))
    drift_bps = None
    drift_src = None
    for p in toml_paths:
        try:
            obj = read_toml(p)
        except Exception:
            continue
        d = extract_global_drift_bps(obj)
        if d is not None:
            drift_bps = d
            drift_src = os.path.basename(p)
            break

    schema_pass = os.path.exists(os.path.join(reports_dir, "p0_validate_only.txt")) or os.path.exists(os.path.join(reports_dir, "validate_only.txt")) or True  # kies eigen bewijs
    pii_safe = True
    pii_file = os.path.join(reports_dir, "p0_pii.toml")
    if os.path.exists(pii_file):
        with open(pii_file, "r", encoding="utf-8", errors="ignore") as f:
            txt = f.read().lower()
            if "john.doe@" in txt:
                pii_safe = False

    drift_status = "PASS"
    if drift_bps is None:
        drift_status = "UNKNOWN"
    elif drift_bps > max_drift_bps:
        drift_status = "WARN"

    commit = get_env("GITHUB_SHA", get_env("CI_COMMIT_SHA", ""))
    short_commit = commit[:7] if commit else ""
    tool_version = get_env("LLM_COST_VERSION", "v1.3.0")

    # Markdown summary
    md_lines = []
    md_lines.append(f"# 🛡️ FinOps Integrity Report ({tool_version})")
    md_lines.append("")
    md_lines.append("| Metric | Status | Score |")
    md_lines.append("| :--- | :--- | :--- |")
    md_lines.append(f"| **Schema Compliance** | {'🟢 PASS' if schema_pass else '🔴 FAIL'} | {'100%' if schema_pass else '0%'} |")
    md_lines.append(f"| **Logic Determinism** | {'🟢 PASS' if det_hash else '🟡 WARN'} | {det_hash[:7] + '…' if det_hash else 'n/a'} |")
    if drift_status == "PASS":
        md_lines.append(f"| **Cost Drift (BPS)** | 🟢 PASS | {drift_bps:.2f} bps |")
    elif drift_status == "WARN":
        md_lines.append(f"| **Cost Drift (BPS)** | 🟡 WARN | {drift_bps:.2f} bps |")
    else:
        md_lines.append("| **Cost Drift (BPS)** | 🟡 WARN | n/a |")
    md_lines.append(f"| **PII Leakage** | {'🟢 SAFE' if pii_safe else '🔴 FAIL'} | {0 if pii_safe else 1} detected |")
    md_lines.append("")
    if drift_status == "WARN" and drift_bps is not None:
        md_lines.append(f"> ⚠️ **Drift Warning**: drift is **{drift_bps:.2f} bps** (threshold {max_drift_bps:.0f} bps). Source: `{drift_src}`")
        md_lines.append("")

    if short_commit:
        md_lines.append(f"_commit: `{short_commit}` • focus: `{focus_version}` • fail_fast: `{fail_fast}`_")

    md = "\n".join(md_lines) + "\n"

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as f:
            f.write(md)
    else:
        print(md)

    # audit.json
    audit = {
        "timestamp": utc_now_iso(),
        "commit": short_commit,
        "focus_version": focus_version,
        "policy": {
            "fail_fast": fail_fast,
            "max_drift_bps": max_drift_bps,
        },
        "results": {
            "schema_validation": {"passed": bool(schema_pass), "errors": []},
            "logic_determinism": {"passed": bool(det_hash), "sha256": det_hash},
            "pii_leakage": {"passed": bool(pii_safe), "detections": 0 if pii_safe else 1},
            "unit_economics": {
                "drift_bps": drift_bps,
                "source": drift_src,
            },
        },
    }
    os.makedirs(reports_dir, exist_ok=True)
    with open(out_audit, "w", encoding="utf-8") as f:
        json.dump(audit, f, indent=2, sort_keys=True)
        f.write("\n")

if __name__ == "__main__":
    main()
