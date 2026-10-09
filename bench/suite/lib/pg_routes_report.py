#!/usr/bin/env python3
"""Validate and summarize the focused PostgreSQL route benchmark."""
import argparse
import csv
import json
import math
import re
import statistics
import sys
from pathlib import Path

FIRST = re.compile(r"requests=(\d+)\s+rps=([\d.]+)\s+timeouts=(\d+)\s+errors=(\d+)\s+bad_statuses=(\d+)\s+expected_status=(\d+)")
PERCENTILES = re.compile(r"p50=([\d.]+).*?p90=([\d.]+).*?p99=([\d.]+).*?p99\.9=([\d.]+)")
PROFILE = re.compile(r"PG_PROFILE responses=(\d+) missing=(\d+)")
DURATION = re.compile(r"^\s*([a-z_]+) us: mean=([\d.]+) p50=([\d.]+) p90=([\d.]+) p99=([\d.]+) max=([\d.]+)$", re.M)


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None


def parse_latgen(path):
    try:
        text = Path(path).read_text(errors="replace")
    except OSError:
        return {}, "missing latgen log"
    first = FIRST.search(text)
    pct = PERCENTILES.search(text)
    pg = PROFILE.search(text)
    out = {}
    if first:
        out.update(requests=int(first[1]), rps=float(first[2]), timeouts=int(first[3]),
                   errors=int(first[4]), bad_statuses=int(first[5]), expected_status=int(first[6]))
    if pct:
        out.update(p50_ms=float(pct[1]), p90_ms=float(pct[2]), p99_ms=float(pct[3]), p99_9_ms=float(pct[4]))
    if pg:
        out.update(profile_responses=int(pg[1]), profile_missing=int(pg[2]))
    for label, mean, p50, p90, p99, maximum in DURATION.findall(text):
        out[label] = {"mean_us": float(mean), "p50_us": float(p50), "p90_us": float(p90),
                      "p99_us": float(p99), "max_us": float(maximum)}
    if not first:
        return out, "latgen did not report a completed sample"
    return out, None


def check_log(path, expected_status):
    values, error = parse_latgen(path)
    if error:
        print(error, file=sys.stderr)
        return 1
    problems = []
    if values.get("requests", 0) == 0:
        problems.append("no completed responses")
    if values.get("expected_status") != expected_status:
        problems.append(f"latgen expected status {values.get('expected_status')}, wanted {expected_status}")
    for key in ("timeouts", "errors", "bad_statuses"):
        if values.get(key, 0):
            problems.append(f"{key}={values[key]}")
    if values.get("profile_missing", 1) or values.get("profile_responses") != values.get("requests"):
        problems.append("missing or mismatched PG profile headers")
    if problems:
        print("warmup invalid: " + ", ".join(problems), file=sys.stderr)
        return 1
    return 0


def read_pg_stats(path):
    try:
        with open(path, newline="") as f:
            rows = list(csv.DictReader(f, delimiter="\t"))
    except OSError:
        return {}
    out = {}
    for row in rows:
        try:
            key = row["queryid"]
            out[key] = {"calls": int(row["calls"]), "rows": int(row["rows"]),
                        "total_exec_time": float(row["total_exec_time"])}
        except (KeyError, TypeError, ValueError):
            continue
    return out


def load_metrics(sample_dir, busy_limit, steal_limit):
    sample_dir = Path(sample_dir)
    meta = read_json(sample_dir / "meta.json") or {}
    values, parse_error = parse_latgen(sample_dir / "latgen.log")
    before, after = read_pg_stats(sample_dir / "pg-before.tsv"), read_pg_stats(sample_dir / "pg-after.tsv")
    calls = rows = 0
    exec_ms = 0.0
    for key in set(before) | set(after):
        b, a = before.get(key, {}), after.get(key, {})
        calls += a.get("calls", 0) - b.get("calls", 0)
        rows += a.get("rows", 0) - b.get("rows", 0)
        exec_ms += a.get("total_exec_time", 0.0) - b.get("total_exec_time", 0.0)
    pg = {"calls": calls, "rows": rows, "total_exec_ms": round(exec_ms, 3),
          "mean_exec_ms": round(exec_ms / calls, 6) if calls > 0 else None}
    api = read_json(sample_dir / "api-sampler.json") or {}
    db = read_json(sample_dir / "postgres-sampler.json") or {}
    loadgen = read_json(sample_dir / "loadgen-sampler.json") or {}
    reasons = []
    if parse_error:
        reasons.append(parse_error)
    if meta.get("latgen_exit") != 0:
        reasons.append(f"latgen exit={meta.get('latgen_exit')}")
    if values.get("requests", 0) <= 0:
        reasons.append("no completed responses")
    if values.get("expected_status") != meta.get("expected_status"):
        reasons.append(f"latgen expected status {values.get('expected_status')} != {meta.get('expected_status')}")
    for key in ("timeouts", "errors", "bad_statuses"):
        if values.get(key, 0):
            reasons.append(f"{key}={values[key]}")
    if values.get("profile_missing", 1) or values.get("profile_responses") != values.get("requests"):
        reasons.append("incomplete PG profile headers")
    if pg["calls"] != values.get("requests"):
        reasons.append(f"SQL calls {pg['calls']} != HTTP responses {values.get('requests', 0)}")
    if not api or not db or not loadgen:
        reasons.append("missing API, PostgreSQL, or load-generator sampler data")
    if loadgen and loadgen.get("avg_cpu_cores", 0) >= busy_limit:
        reasons.append(f"load generator saturated ({loadgen.get('avg_cpu_cores')} CPU cores)")
    steal = meta.get("cpu_steal_pct")
    if steal is None or steal > steal_limit:
        reasons.append(f"CPU steal {steal}% exceeds {steal_limit}% or is unavailable")
    metrics = {"latgen": values, "postgres": pg, "api": api, "postgres_process": db, "loadgen": loadgen,
               "valid": not reasons, "invalid_reasons": reasons}
    meta["metrics"] = metrics
    with open(sample_dir / "meta.json", "w") as f:
        json.dump(meta, f, indent=2)
        f.write("\n")
    print(("VALID" if not reasons else "INVALID: " + "; ".join(reasons)) + f" | {sample_dir}")
    return meta


def median(values, digits=3):
    values = [x for x in values if isinstance(x, (int, float)) and math.isfinite(x)]
    return round(statistics.median(values), digits) if values else None


def fmt(value, digits=2):
    return "—" if value is None else f"{value:.{digits}f}"


def language_median(samples, section, key):
    values = []
    for sample in samples:
        if not sample.get("metrics", {}).get("valid"):
            continue
        data = sample.get("metrics", {}).get(section, {})
        value = data.get(key)
        if value is not None:
            values.append(value)
    return median(values)


def report(run_dir, busy_limit, steal_limit):
    run_dir = Path(run_dir)
    env = read_json(run_dir / "env.json") or {}
    samples = []
    for path in sorted(run_dir.glob("raw/**/meta.json")):
        item = read_json(path)
        if item:
            if "metrics" not in item:
                item = load_metrics(path.parent, busy_limit, steal_limit)
            samples.append(item)
    routes = env.get("matrix", {}).get("routes", ["point", "orders", "summary", "insert"])
    concurrencies = env.get("matrix", {}).get("concurrencies", [64, 512])
    rounds = env.get("matrix", {}).get("rounds", 0)
    expected_per_language = rounds * 2
    lines = [f"# Targeted PostgreSQL benchmark: {env.get('run_id', run_dir.name)}", "",
             f"Commit: `{env.get('git_sha', 'unknown')}` (working tree dirty: `{env.get('git_dirty', 'unknown')}`)",
             f"Seed: {env.get('seed', {}).get('users', '?')} users / {env.get('seed', {}).get('orders', '?')} orders; "
             f"PostgreSQL {env.get('database', {}).get('server_version_num', '?')}; "
             f"pool size {env.get('database', {}).get('pool_size', '?')}; Go `{env.get('toolchains', {}).get('go', '?')}`.",
             f"CPU layout: API/PostgreSQL `{env.get('host', {}).get('postgres_cpus', '?')}`, "
             f"load generator `{env.get('host', {}).get('loadgen_cpu', '?')}`; "
             f"memory {env.get('host', {}).get('memory_total_kb', 0) // 1024} MiB.", "",
             "Results are medians over valid samples only. Each Slang/Go ratio is kept separate by route and concurrency. "
             "The 98% gate requires every expected sample to be valid and Slang throughput to be at least 98% of Go.", "",
             "| Route | Clients | Slang / Go RPS | Slang / Go | p99 ms S/G | Pool p99 us S/G | Client p99 us S/G | PG ms/query S/G | CPU cores S/G | Peak RSS MiB S/G | Valid samples S/G | Gate |",
             "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|"]
    gates = []
    for route in routes:
        for clients in concurrencies:
            pair = {}
            for lang in ("slang", "go"):
                pair[lang] = [s for s in samples if s.get("route") == route and s.get("concurrency") == clients and s.get("language") == lang]
            s, g = pair["slang"], pair["go"]
            srps, grps = language_median(s, "latgen", "rps"), language_median(g, "latgen", "rps")
            ratio = (100 * srps / grps) if srps is not None and grps else None
            valid_s = sum(bool(x.get("metrics", {}).get("valid")) for x in s)
            valid_g = sum(bool(x.get("metrics", {}).get("valid")) for x in g)
            complete = len(s) == expected_per_language and len(g) == expected_per_language
            valid = complete and valid_s == expected_per_language and valid_g == expected_per_language
            gate = "PASS" if valid and ratio is not None and ratio >= 98 else ("OPEN" if valid else "INVALID")
            gates.append(gate)
            def pairfmt(section, key, digits=2):
                return f"{fmt(language_median(s, section, key), digits)} / {fmt(language_median(g, section, key), digits)}"
            rss_s = median([x["metrics"]["api"]["peak_rss_kb"] / 1024 for x in s if x.get("metrics", {}).get("valid") and x.get("metrics", {}).get("api")])
            rss_g = median([x["metrics"]["api"]["peak_rss_kb"] / 1024 for x in g if x.get("metrics", {}).get("valid") and x.get("metrics", {}).get("api")])
            lines.append(f"| {route} | {clients} | {fmt(srps, 0)} / {fmt(grps, 0)} | {fmt(ratio, 1)}% | "
                         f"{pairfmt('latgen', 'p99_ms')} | {pairfmt('pool_acquire', 'p99_us')} | "
                         f"{pairfmt('client_query_row_decode_and_release', 'p99_us')} | {pairfmt('postgres', 'mean_exec_ms', 4)} | "
                         f"{pairfmt('api', 'avg_cpu_cores')} | {fmt(rss_s, 1)} / {fmt(rss_g, 1)} | "
                         f"{valid_s}/{expected_per_language} / {valid_g}/{expected_per_language} | {gate} |")
    lines += ["", "## Raw samples", "", "Each sample directory retains the request latencies, server log, sampler outputs, "
              "and before/after `pg_stat_statements` snapshots.", "",
              "| Route | Clients | Round | Position | Language | RPS | p99 ms | SQL calls | PG ms/query | Loadgen CPU | Steal % | Validity |",
              "|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---|"]
    for x in sorted(samples, key=lambda v: (v.get("route", ""), v.get("concurrency", 0), v.get("round", 0), v.get("position", 0))):
        m=x.get("metrics",{}); lat=m.get("latgen",{}); pg=m.get("postgres",{}); gen=m.get("loadgen",{})
        reason="valid" if m.get("valid") else "; ".join(m.get("invalid_reasons", []))
        lines.append(f"| {x.get('route')} | {x.get('concurrency')} | {x.get('round')} | {x.get('position')} | {x.get('language')} | "
                     f"{fmt(lat.get('rps'),0)} | {fmt(lat.get('p99_ms'))} | {pg.get('calls','—')} | {fmt(pg.get('mean_exec_ms'),4)} | "
                     f"{fmt(gen.get('avg_cpu_cores'))} | {fmt(x.get('cpu_steal_pct'))} | {reason} |")
    (run_dir / "summary.md").write_text("\n".join(lines) + "\n")
    result = {"schema": "slang-pg-routes/1", "expected_samples": expected_per_language * 2 * len(routes) * len(concurrencies),
              "samples_found": len(samples), "invalid_samples": sum(not s.get("metrics", {}).get("valid") for s in samples),
              "gates": gates, "acceptance_passed": bool(gates) and all(x == "PASS" for x in gates)}
    (run_dir / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"Wrote {run_dir / 'summary.md'} ({len(samples)} samples; {result['invalid_samples']} invalid; acceptance {'passed' if result['acceptance_passed'] else 'open'}).")
    return 0 if len(samples) == result["expected_samples"] and result["invalid_samples"] == 0 else 2


def main():
    parser = argparse.ArgumentParser()
    subs = parser.add_subparsers(dest="action", required=True)
    check = subs.add_parser("check")
    check.add_argument("log")
    check.add_argument("expected_status", type=int)
    sample = subs.add_parser("sample")
    sample.add_argument("directory")
    sample.add_argument("busy_limit", type=float)
    sample.add_argument("steal_limit", type=float)
    final = subs.add_parser("report")
    final.add_argument("directory")
    final.add_argument("--loadgen-busy-limit", type=float, default=0.95)
    final.add_argument("--steal-limit-pct", type=float, default=2.0)
    args = parser.parse_args()
    if args.action == "check":
        return check_log(args.log, args.expected_status)
    if args.action == "sample":
        load_metrics(args.directory, args.busy_limit, args.steal_limit)
        return 0
    return report(args.directory, args.loadgen_busy_limit, args.steal_limit_pct)


if __name__ == "__main__":
    raise SystemExit(main())
