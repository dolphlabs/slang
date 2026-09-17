"""light/compute for Python: CC_TASKS tasks over a process pool, one
process per core, each task doing exactly bench/compute/main.go's work.
See bench/SPEC.md."""
import multiprocessing as mp
import os
import time


def count_primes_range(lo, hi):
    count = 0
    for i in range(lo, hi):
        is_prime = i >= 2
        d = 2
        while d * d <= i:
            if i % d == 0:
                is_prime = False
            d += 1
        if is_prime:
            count += 1
    return count


def alloc_and_sum(n):
    xs = list(range(n))
    m = {str(i): i for i in range(n)}
    return sum(xs) + sum(m.values())


def task(args):
    work, alloc = args
    return count_primes_range(0, work), alloc_and_sum(alloc)


def main():
    tasks = int(os.environ.get("CC_TASKS", "1000"))
    work = int(os.environ.get("CC_WORK", "20000"))
    alloc = int(os.environ.get("CC_ALLOC", "200"))
    procs = int(os.environ.get("WORKERS") or (len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else os.cpu_count()))
    print(f"concurrent_compute: tasks={tasks} work_n={work} alloc_n={alloc}", flush=True)
    t0 = time.monotonic()
    with mp.get_context("fork").Pool(procs) as pool:
        results = pool.map(task, [(work, alloc)] * tasks, chunksize=max(1, tasks // (procs * 4)))
    wall = int((time.monotonic() - t0) * 1000)
    primes = sum(r[0] for r in results)
    alloc_sum = sum(r[1] for r in results)
    tps = tasks * 1000 // wall if wall > 0 else 0
    print(f"RESULT tasks={tasks} work_n={work} alloc_n={alloc} wall_ms={wall} total_primes={primes} "
          f"total_alloc_sum={alloc_sum} tasks_per_sec={tps}")


if __name__ == "__main__":
    main()
