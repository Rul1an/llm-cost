#!/usr/bin/env python3
import csv, random, uuid, argparse

def gen_1m(path, rows=1_000_000, prompts=1000):
    prompt_ids = [f"prompt-{i}" for i in range(prompts)]
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["ChargePeriodStart","ChargePeriodEnd","ResourceId","BilledCost","ChargeCategory","Tags"])
        for _ in range(rows):
            rid = random.choice(prompt_ids)
            cost = f"{random.uniform(0.001, 0.1):.6f}"
            tags = '{"model":"gpt-4o","scenario":"default","x-call-count":"1"}'
            w.writerow(["2025-01-01","2025-01-31",rid,cost,"Usage",tags])

def gen_high_cardinality(path, rows=100_000):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["ChargePeriodStart","ChargePeriodEnd","ResourceId","BilledCost","ChargeCategory","Tags"])
        for _ in range(rows):
            # Use matching ID to trigger grouping
            rid = "search-query"
            # Unique model to trigger cardinality explosion
            unique_model = f"model-{uuid.uuid4()}"
            tags = f'{{"model":"{unique_model}"}}'
            w.writerow(["2025-01-01","2025-01-31",rid,"0.010000","Usage",tags])

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["1m","high-cardinality"], required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--rows", type=int, default=None)
    ap.add_argument("--prompts", type=int, default=1000)
    args = ap.parse_args()

    if args.mode == "1m":
        gen_1m(args.out, rows=args.rows or 1_000_000, prompts=args.prompts)
    else:
        # Default row count for high cardinality is small if not matching 1m default?
        # User python snippet says "gen_high_cardinality(args.out, rows=args.rows or 100_000)"
        gen_high_cardinality(args.out, rows=args.rows or 100_000)
