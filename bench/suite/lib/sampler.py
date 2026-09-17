#!/usr/bin/env python3
"""Sample a process tree's memory and CPU until told to stop. Linux only.

    python3 sampler.py <pid> <out.json> [interval_s=0.2]

Every interval it walks <pid> and all of its descendants through /proc and
sums resident memory (RSS) and CPU time (utime+stime). A multi-process
server (Node cluster, Python workers, Bun children) is measured as a whole,
which is what it costs to run.

Stops on SIGTERM/SIGINT or when the root process exits, then writes:

    {"peak_rss_kb": ..., "avg_rss_kb": ..., "cpu_seconds": ...,
     "wall_seconds": ..., "avg_cpu_cores": ..., "samples": N,
     "peak_processes": ...}
"""
import json
import os
import signal
import sys
import time

CLK_TCK = os.sysconf("SC_CLK_TCK")
PAGE_KB = os.sysconf("SC_PAGE_SIZE") // 1024
stop = False


def on_signal(*_):
    global stop
    stop = True


def children_map():
    kids = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open(f"/proc/{name}/stat", "rb") as f:
                stat = f.read()
        except OSError:
            continue
        # the command name may contain spaces and parentheses: split after the last ')'
        fields = stat[stat.rfind(b")") + 2:].split()
        ppid = int(fields[1])
        kids.setdefault(ppid, []).append(int(name))
    return kids


def tree(root):
    kids = children_map()
    out, todo = [], [root]
    while todo:
        pid = todo.pop()
        out.append(pid)
        todo.extend(kids.get(pid, ()))
    return out


def sample(pids):
    rss_kb = 0
    ticks = 0
    alive = 0
    for pid in pids:
        try:
            with open(f"/proc/{pid}/statm", "rb") as f:
                rss_kb += int(f.read().split()[1]) * PAGE_KB
            with open(f"/proc/{pid}/stat", "rb") as f:
                stat = f.read()
            fields = stat[stat.rfind(b")") + 2:].split()
            # utime, stime, cutime, cstime: fields 14-17 of stat, 11-14 after the name
            ticks += int(fields[11]) + int(fields[12]) + int(fields[13]) + int(fields[14])
            alive += 1
        except (OSError, IndexError, ValueError):
            continue
    return rss_kb, ticks, alive


def main(root, out_path, interval):
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    t0 = time.monotonic()
    peak_rss = peak_procs = 0
    rss_total = 0
    samples = 0
    first_ticks = None
    last_ticks = 0
    # CPU of processes that exit mid-run would vanish from the sum; keep the
    # best total seen per pid so a short-lived worker still counts.
    cpu_by_pid = {}
    while not stop:
        if not os.path.exists(f"/proc/{root}"):
            break
        pids = tree(root)
        rss_kb, _, alive = sample(pids)
        for pid in pids:
            try:
                with open(f"/proc/{pid}/stat", "rb") as f:
                    stat = f.read()
                fields = stat[stat.rfind(b")") + 2:].split()
                t = int(fields[11]) + int(fields[12])
                cpu_by_pid[pid] = max(cpu_by_pid.get(pid, 0), t)
            except (OSError, IndexError, ValueError):
                pass
        ticks = sum(cpu_by_pid.values())
        if first_ticks is None:
            first_ticks = ticks
        last_ticks = ticks
        peak_rss = max(peak_rss, rss_kb)
        peak_procs = max(peak_procs, alive)
        rss_total += rss_kb
        samples += 1
        time.sleep(interval)
    wall = time.monotonic() - t0
    cpu_seconds = (last_ticks - (first_ticks or 0)) / CLK_TCK
    result = {
        "peak_rss_kb": peak_rss,
        "avg_rss_kb": rss_total // samples if samples else 0,
        "cpu_seconds": round(cpu_seconds, 3),
        "wall_seconds": round(wall, 3),
        "avg_cpu_cores": round(cpu_seconds / wall, 3) if wall > 0 else 0,
        "samples": samples,
        "peak_processes": peak_procs,
    }
    with open(out_path, "w") as f:
        json.dump(result, f)


if __name__ == "__main__":
    main(int(sys.argv[1]), sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else 0.2)
