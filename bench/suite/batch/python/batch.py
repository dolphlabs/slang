"""heavy/batch in Python: multiprocessing over newline-aligned byte ranges
of an mmap, dicts per process merged at the end. See bench/SPEC.md."""
import mmap
import multiprocessing as mp
import os
import sys

BLOCK = 16 * 1024 * 1024


def work(args):
    path, start, end = args
    regions = {}
    users = {}
    skus = {}
    rows = 0
    ug = users.get
    sg = skus.get
    with open(path, "rb") as f:
        mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        pos = start
        while pos < end:
            stop = min(pos + BLOCK, end)
            if stop < end:
                stop = mm.find(b"\n", stop - 1) + 1 or end
            for line in mm[pos:stop].splitlines():
                _ts, user, sku, qty, price, region = line.split(b",")
                qty = int(qty)
                rev = qty * int(price)
                r = regions.get(region)
                if r is None:
                    r = regions[region] = [0, 0, 0]
                r[0] += 1
                r[1] += qty
                r[2] += rev
                user = int(user)
                users[user] = ug(user, 0) + rev
                skus[sku] = sg(sku, 0) + rev
                rows += 1
            pos = stop
        mm.close()
    return rows, regions, users, skus


def main(path):
    size = os.path.getsize(path)
    workers = int(os.environ.get("WORKERS") or len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else os.cpu_count())
    workers = min(workers, size // 65536 + 1)
    bounds = [0]
    with open(path, "rb") as f:
        mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) if size else None
        for w in range(1, workers):
            at = size // workers * w
            nl = mm.find(b"\n", at - 1)
            bounds.append(max(bounds[-1], nl + 1 if nl >= 0 else size))
        if mm:
            mm.close()
    bounds.append(size)
    ranges = [(path, bounds[i], bounds[i + 1]) for i in range(workers)]
    with mp.get_context("fork").Pool(workers) as pool:
        parts = pool.map(work, ranges)

    rows = 0
    regions = {}
    users, skus = {}, {}
    for r, reg, u, s in parts:
        rows += r
        for code, (c, q, v) in reg.items():
            t = regions.setdefault(code, [0, 0, 0])
            t[0] += c
            t[1] += q
            t[2] += v
        if not users:
            users, skus = u, s
            continue
        ug, sg = users.get, skus.get
        for k, v in u.items():
            users[k] = ug(k, 0) + v
        for k, v in s.items():
            skus[k] = sg(k, 0) + v

    import heapq
    top_users = heapq.nsmallest(100, users.items(), key=lambda kv: (-kv[1], kv[0]))
    top_skus = heapq.nsmallest(10, skus.items(), key=lambda kv: (-kv[1], kv[0]))
    out = [f"rows={rows}"]
    for code in sorted(regions):
        c, q, v = regions[code]
        out.append(f"region={code.decode()} count={c} qty={q} revenue={v}")
    for i, (u, v) in enumerate(top_users, 1):
        out.append(f"top_user rank={i} user_id={u} revenue={v}")
    for i, (s, v) in enumerate(top_skus, 1):
        out.append(f"top_sku rank={i} sku={s.decode()} revenue={v}")
    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main(sys.argv[1])
