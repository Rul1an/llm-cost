#!/usr/bin/env python3
"""
Generate large-scale test data for llm-cost performance testing.

Usage:
    python3 generate_scale_data.py --rows 1000000 --output actuals-1m.focus.csv
    python3 generate_scale_data.py --rows 100000 --cardinality 100000 --output high-cardinality.focus.csv
"""

import argparse
import csv
import random
import json
import sys
from datetime import datetime, timedelta

# Realistic prompt names
PROMPT_PREFIXES = [
    "search", "summarize", "classify", "translate", "review",
    "generate", "analyze", "extract", "format", "validate"
]

PROMPT_SUFFIXES = [
    "query", "article", "intent", "content", "code",
    "response", "data", "text", "request", "output"
]

TEAMS = ["discovery", "content", "ml", "platform", "i18n", "growth", "security"]
APPS = ["search", "cms", "router", "ci-tools", "localization", "onboarding", "auth"]
MODELS = ["gpt-4o", "gpt-4o-mini", "claude-3-5-sonnet", "claude-3-haiku", "gemini-1.5-pro"]

def generate_prompt_id(index: int, cardinality: int) -> str:
    """Generate prompt ID with controlled cardinality."""
    if cardinality >= 100000:
        # High cardinality: unique per row
        return f"request-{index:08d}"
    else:
        # Normal cardinality: reuse prompt names
        prefix = random.choice(PROMPT_PREFIXES)
        suffix = random.choice(PROMPT_SUFFIXES)
        variant = index % cardinality
        return f"{prefix}-{suffix}-{variant}"

def generate_tags(prompt_id: str) -> str:
    """Generate realistic tags JSON."""
    tags = {
        "team": random.choice(TEAMS),
        "app": random.choice(APPS),
        "model": random.choice(MODELS),
        "env": "production" if random.random() > 0.1 else "staging",
    }
    
    # Add cache hit ratio for some rows
    if random.random() > 0.3:
        tags["x-cache-hit-ratio"] = str(round(random.uniform(0.1, 0.9), 2))
    
    return json.dumps(tags)

def generate_cost() -> float:
    """Generate realistic cost value."""
    # Most calls are cheap, some are expensive
    if random.random() > 0.95:
        # 5% expensive calls
        return round(random.uniform(0.1, 1.0), 6)
    elif random.random() > 0.7:
        # 25% medium calls
        return round(random.uniform(0.01, 0.1), 6)
    else:
        # 70% cheap calls
        return round(random.uniform(0.001, 0.01), 6)

def main():
    parser = argparse.ArgumentParser(description="Generate scale test data for llm-cost")
    parser.add_argument("--rows", type=int, default=100000, help="Number of rows to generate")
    parser.add_argument("--cardinality", type=int, default=1000, help="Number of unique ResourceIds")
    parser.add_argument("--output", type=str, default="scale-test.focus.csv", help="Output file path")
    parser.add_argument("--days", type=int, default=30, help="Number of days to spread data across")
    args = parser.parse_args()
    
    print(f"Generating {args.rows:,} rows with {args.cardinality:,} unique ResourceIds...")
    
    start_date = datetime(2025, 1, 1)
    
    with open(args.output, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow([
            'ChargePeriodStart',
            'ChargePeriodEnd',
            'ResourceId',
            'BilledCost',
            'ChargeCategory',
            'ServiceName',
            'Tags'
        ])
        
        for i in range(args.rows):
            # Distribute across days
            day_offset = i % args.days
            charge_date = start_date + timedelta(days=day_offset)
            
            prompt_id = generate_prompt_id(i, args.cardinality)
            cost = generate_cost()
            tags = generate_tags(prompt_id)
            
            writer.writerow([
                charge_date.strftime('%Y-%m-%d'),
                charge_date.strftime('%Y-%m-%d'),
                prompt_id,
                f"{cost:.6f}",
                'Usage',
                'LLM Inference',
                tags
            ])
            
            if (i + 1) % 100000 == 0:
                print(f"  Generated {i + 1:,} rows...")
    
    # Print summary
    file_size = f.tell() if hasattr(f, 'tell') else 0
    print(f"\nDone!")
    print(f"  Output: {args.output}")
    print(f"  Rows: {args.rows:,}")
    print(f"  Unique ResourceIds: {min(args.rows, args.cardinality):,}")
    
    # Estimate file size
    import os
    actual_size = os.path.getsize(args.output)
    print(f"  File size: {actual_size / 1024 / 1024:.1f} MB")

if __name__ == "__main__":
    main()
