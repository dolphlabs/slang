#!/usr/bin/env python3
"""Pre-generated POST /api/quote bodies (bench/SPEC.md), deterministic.

    python3 gen_quote.py <out_dir> [bodies=8] [items=2000]
writes quote_0.json .. quote_{n-1}.json
"""
import json
import os
import sys

REGIONS = ["US", "CA", "UK", "EU", "DE", "FR", "JP", "IN", "BR", "NG", "AU"]


def lcg(seed):
    x = seed
    while True:
        x = (x * 6364136223846793005 + 1442695040888963407) & ((1 << 64) - 1)
        yield x >> 33


def main(out, bodies=8, items=2000):
    os.makedirs(out, exist_ok=True)
    for b in range(bodies):
        rnd = lcg(1000 + b)
        lines = []
        for _ in range(items):
            lines.append({
                "sku": "SKU-%05d" % (next(rnd) % 100000),
                "qty": 1 + next(rnd) % 25,
                "price_cents": 50 + next(rnd) % 99950,
            })
        body = {"region": REGIONS[b % len(REGIONS)], "items": lines}
        with open(os.path.join(out, "quote_%d.json" % b), "w") as f:
            json.dump(body, f, separators=(",", ":"))


if __name__ == "__main__":
    main(sys.argv[1], *(int(a) for a in sys.argv[2:]))
