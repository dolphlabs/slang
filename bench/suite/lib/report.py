#!/usr/bin/env python3
"""Aggregate a suite run into results.json and summary.md.

    python3 report.py bench/results/<run id>

Reads env.json, builds.json, correctness.json and runs.jsonl written by
run.sh, parses each raw wrk/wrk2 log and resource sample, and writes:

  results.json  schema "slang-bench/1": every measurement, plus the median
                of each (workload, scenario, load, language) across rounds
  summary.md    the medians as tables, one per workload and load

The result format is documented in bench/CURSOR.md.
"""
import json
import os
import re
import statistics
import sys

UNIT_MS = {"us": 0.001, "µs": 0.001, "ms": 1.0, "s": 1000.0, "m": 60000.0, "h": 3600000.0}


def to_ms(value, unit):
    return float(value) * UNIT_MS[unit]


def parse_wrk(text):
    out = {"rps": None, "latency_ms": {}, "errors": {}, "requests": None, "non_2xx": 0}
    m = re.search(r"Requests/sec:\s+([\d.]+)", text)
    if m:
        out["rps"] = float(m.group(1))
    m = re.search(r"(\d+) requests in ([\d.]+)(\w+)", text)
    if m:
        out["requests"] = int(m.group(1))
    m = re.search(r"Non-2xx or 3xx responses:\s+(\d+)", text)
    if m:
        out["non_2xx"] = int(m.group(1))
    m = re.search(r"Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)", text)
    if m:
        out["errors"] = dict(zip(("connect", "read", "write", "timeout"), map(int, m.groups())))
    # wrk: "     50%    1.23ms"; wrk2: " 50.000%    1.23ms"
    for pct, value, unit in re.findall(r"^\s*(\d+(?:\.\d+)?)%\s+([\d.]+)(us|µs|ms|s|m|h)\s*$", text, re.M):
        key = {"50": "p50", "75": "p75", "90": "p90", "99": "p99", "99.9": "p99_9",
               "99.99": "p99_99", "100": "max"}.get(pct.rstrip("0").rstrip(".") if "." in pct else pct)
        if key and key not in out["latency_ms"]:
            out["latency_ms"][key] = round(to_ms(value, unit), 3)
    return out


def parse_compute(text):
    m = re.search(r"^RESULT (.*)$", text, re.M)
    if not m:
        return {}
    return {k: int(v) for k, v in (kv.split("=") for kv in m.group(1).split())}


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def median(values):
    values = [v for v in values if v is not None]
    return round(statistics.median(values), 3) if values else None


def main(run_dir):
    env = load_json(os.path.join(run_dir, "env.json")) or {}
    builds = load_json(os.path.join(run_dir, "builds.json")) or {}
    correctness = load_json(os.path.join(run_dir, "correctness.json")) or {}
    rows = []
    runs_path = os.path.join(run_dir, "runs.jsonl")
    if os.path.exists(runs_path):
        with open(runs_path) as f:
            rows = [json.loads(line) for line in f if line.strip()]

    measurements = []
    for r in rows:
        m = {k: r.get(k) for k in ("tier", "workload", "scenario", "lang", "round", "connections", "rate", "tool")}
        m = {k: v for k, v in m.items() if v is not None}
        log_text = ""
        if r.get("log"):
            try:
                with open(os.path.join(run_dir, r["log"]), errors="replace") as f:
                    log_text = f.read()
            except OSError:
                pass
        if r["workload"] in ("http", "api"):
            m.update(parse_wrk(log_text))
            err = sum(m["errors"].values()) + m["non_2xx"]
            m["error_rate"] = round(err / m["requests"], 6) if m.get("requests") else None
        elif r["workload"] == "compute":
            res = parse_compute(log_text)
            m["exit"] = r.get("exit")
            m["wall_ms"] = res.get("wall_ms")
            m["tasks_per_sec"] = res.get("tasks_per_sec")
            m["total_primes"] = res.get("total_primes")
            m["total_alloc_sum"] = res.get("total_alloc_sum")
        elif r["workload"] == "batch":
            m["exit"] = r.get("exit")
            m["wall_ms"] = r.get("wall_ms")
            m["output_sha256"] = r.get("output_sha256")
        sample = load_json(os.path.join(run_dir, r["sample"])) if r.get("sample") else None
        if sample:
            m["peak_rss_mb"] = round(sample["peak_rss_kb"] / 1024, 1)
            m["avg_cpu_cores"] = sample["avg_cpu_cores"]
            m["cpu_seconds"] = sample["cpu_seconds"]
        db = load_json(os.path.join(run_dir, r["db_sample"])) if r.get("db_sample") else None
        if db:
            m["db_avg_cpu_cores"] = db["avg_cpu_cores"]
        m["raw_log"] = r.get("log")
        measurements.append(m)

    # compute: every language must agree with Go's totals
    ref = next((m for m in measurements if m["workload"] == "compute" and m["lang"] == "go"), None)
    for m in measurements:
        if m["workload"] == "compute" and ref and ref.get("total_primes") is not None:
            ok = m.get("total_primes") == ref["total_primes"] and m.get("total_alloc_sum") == ref["total_alloc_sum"]
            correctness.setdefault("compute", {})[m["lang"]] = {"status": "pass" if ok else "fail", "detail": ""}
    # batch at full scale: outputs are compared with each other (every language
    # already matched the reference on the check file); record the agreement
    shas = {}
    for m in measurements:
        if m["workload"] == "batch" and m.get("exit") == 0 and m.get("output_sha256"):
            shas.setdefault(m["output_sha256"], set()).add(m["lang"])
    if shas:
        majority = max(shas, key=lambda s: len(shas[s]))
        for m in measurements:
            if m["workload"] == "batch":
                m["agrees_with_majority"] = m.get("output_sha256") == majority

    groups = {}
    for m in measurements:
        key = (m["tier"], m["workload"], m["scenario"], m.get("tool", ""), m.get("connections"), m.get("rate"), m["lang"])
        groups.setdefault(key, []).append(m)
    summary = []
    for (tier, workload, scenario, tool, conns, rate, lang), ms in sorted(groups.items(), key=lambda kv: tuple(str(x) for x in kv[0])):
        s = {"tier": tier, "workload": workload, "scenario": scenario, "lang": lang, "rounds": len(ms)}
        if tool:
            s["tool"] = tool
        if conns is not None:
            s["connections"] = conns
        if rate is not None:
            s["rate"] = rate
        for field in ("rps", "error_rate", "wall_ms", "tasks_per_sec", "peak_rss_mb", "avg_cpu_cores", "cpu_seconds", "db_avg_cpu_cores"):
            vals = [m.get(field) for m in ms]
            if any(v is not None for v in vals):
                s[field] = median(vals)
        lat = {}
        for p in ("p50", "p90", "p99", "p99_9", "max"):
            vals = [m.get("latency_ms", {}).get(p) for m in ms]
            if any(v is not None for v in vals):
                lat[p] = median(vals)
        if lat:
            s["latency_ms"] = lat
        if workload == "batch":
            s["all_rounds_agree"] = all(m.get("agrees_with_majority") for m in ms)
        summary.append(s)

    result = {"schema": "slang-bench/1", "env": env, "builds": builds, "correctness": correctness,
              "summary": summary, "measurements": measurements}
    with open(os.path.join(run_dir, "results.json"), "w") as f:
        json.dump(result, f, indent=2)

    # ---- summary.md ----
    lines = [f"# Benchmark run {env.get('run_id', '?')}", ""]
    cfg = env.get("config", {})
    lines += [f"- commit `{env.get('git_sha', '?')}`{' (dirty tree)' if env.get('git_dirty') else ''}",
              f"- {env.get('os', '?')}, kernel {env.get('kernel', '?')}, {env.get('nproc', '?')} cpus, {env.get('memory', '?')} RAM",
              f"- cpu split: server `{cfg.get('server_cpus')}` ({cfg.get('workers')} workers), load generator `{cfg.get('loadgen_cpus')}`, database `{cfg.get('db_cpus') or 'unpinned'}`",
              f"- rounds: {cfg.get('rounds')}; medians shown", ""]
    failed = [f"{l} (build)" for l, b in builds.items() if not b.get("ok")]
    for wl, langs in correctness.items():
        failed += [f"{l} ({wl})" for l, c in langs.items() if c.get("status") != "pass"]
    lines.append("**Failed and not measured:** " + (", ".join(failed) if failed else "none"))
    lines.append("")

    def table(title, rows_, cols):
        if not rows_:
            return
        lines.append(f"## {title}")
        lines.append("")
        lines.append("| " + " | ".join(c[0] for c in cols) + " |")
        lines.append("|" + "---|" * len(cols))
        for r in rows_:
            lines.append("| " + " | ".join(c[1](r) for c in cols) + " |")
        lines.append("")

    fmt = lambda v, nd=0: "—" if v is None else (f"{v:,.{nd}f}")
    lat = lambda p: (lambda r: fmt(r.get("latency_ms", {}).get(p), 2))
    http_cols = [("lang", lambda r: r["lang"]), ("req/s", lambda r: fmt(r.get("rps"))),
                 ("p50 ms", lat("p50")), ("p99 ms", lat("p99")), ("p99.9 ms", lat("p99_9")),
                 ("errors", lambda r: fmt((r.get("error_rate") or 0) * 100, 2) + "%"),
                 ("peak RSS MB", lambda r: fmt(r.get("peak_rss_mb"), 1)), ("CPU cores", lambda r: fmt(r.get("avg_cpu_cores"), 2))]
    by = {}
    for s in summary:
        by.setdefault((s["workload"], s["scenario"], s.get("tool"), s.get("connections"), s.get("rate")), []).append(s)
    for (workload, scenario, tool, conns, rate), rows_ in sorted(by.items(), key=lambda kv: tuple(str(x) for x in kv[0])):
        if workload in ("http", "api"):
            rows_.sort(key=lambda r: -(r.get("rps") or 0))
            load = f"fixed {rate}/s (wrk2)" if rate else f"{conns} connections"
            cols = http_cols + ([("DB CPU", lambda r: fmt(r.get("db_avg_cpu_cores"), 2))] if workload == "api" else [])
            table(f"{workload} / {scenario} — {load}", rows_, cols)
        elif workload == "compute":
            rows_.sort(key=lambda r: r.get("wall_ms") or 1e18)
            table("compute", rows_, [("lang", lambda r: r["lang"]), ("wall ms", lambda r: fmt(r.get("wall_ms"))),
                                     ("tasks/s", lambda r: fmt(r.get("tasks_per_sec"))),
                                     ("peak RSS MB", lambda r: fmt(r.get("peak_rss_mb"), 1)),
                                     ("CPU s", lambda r: fmt(r.get("cpu_seconds"), 1))])
        elif workload == "batch":
            rows_.sort(key=lambda r: r.get("wall_ms") or 1e18)
            table("batch", rows_, [("lang", lambda r: r["lang"]), ("wall s", lambda r: fmt((r.get("wall_ms") or 0) / 1000, 2)),
                                   ("peak RSS MB", lambda r: fmt(r.get("peak_rss_mb"), 1)),
                                   ("CPU s", lambda r: fmt(r.get("cpu_seconds"), 1)),
                                   ("output agrees", lambda r: "yes" if r.get("all_rounds_agree") else "NO")])
    with open(os.path.join(run_dir, "summary.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote {run_dir}/results.json and summary.md ({len(measurements)} measurements)")


if __name__ == "__main__":
    main(sys.argv[1])
