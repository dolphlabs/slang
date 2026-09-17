#!/usr/bin/env python3
"""The heavy/batch oracle: the SPEC's report, computed the obvious way.

Slow on purpose (plain loops, no tricks) so it can be trusted. The harness
uses it to verify every implementation at a small scale, then compares the
implementations to each other at full scale.

    python3 batch_reference.py <file.csv>  > report.txt
"""
import collections
import sys


def main(path):
    regions = collections.defaultdict(lambda: [0, 0, 0])
    users = collections.defaultdict(int)
    skus = collections.defaultdict(int)
    rows = 0
    with open(path, "rb") as f:
        for line in f:
            _ts, user, sku, qty, price, region = line.rstrip(b"\n").split(b",")
            qty = int(qty)
            revenue = qty * int(price)
            rows += 1
            r = regions[region]
            r[0] += 1
            r[1] += qty
            r[2] += revenue
            users[int(user)] += revenue
            skus[sku] += revenue
    out = [f"rows={rows}"]
    for code in sorted(regions):
        c, q, v = regions[code]
        out.append(f"region={code.decode()} count={c} qty={q} revenue={v}")
    top_users = sorted(users.items(), key=lambda kv: (-kv[1], kv[0]))[:100]
    for rank, (user, v) in enumerate(top_users, 1):
        out.append(f"top_user rank={rank} user_id={user} revenue={v}")
    top_skus = sorted(skus.items(), key=lambda kv: (-kv[1], kv[0]))[:10]
    for rank, (sku, v) in enumerate(top_skus, 1):
        out.append(f"top_sku rank={rank} sku={sku.decode()} revenue={v}")
    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main(sys.argv[1])
