#!/usr/bin/env python3
"""Agent token benchmark: what it costs an LLM agent to build the same
service in different stacks.

    python3 bench/agent/run.py run [--task T] [--stack S] [--runs N]
    python3 bench/agent/run.py summary [results/<dir>]
    python3 bench/agent/run.py selftest

`run` gives an agent each task's spec (tasks/<task>/SPEC.md, the rules in
tasks/COMMON.md, and one stacks/<stack>.md) in a fresh, empty directory,
lets it work until it stops, then starts what it built (`sh start.sh`) and
runs the task's hidden acceptance test against it over HTTP. The agent's
own usage report is kept next to the verdict. `summary` prints medians per
task and stack. `selftest` checks the acceptance tests against the Python
reference servers in reference/, which is how a test is known to be
correct and passable before any agent is measured with it.

The agent is whatever AGENT_CMD names: a shell command run inside the work
directory, given the prompt on stdin, that prints its final report as JSON
on stdout. The default is Claude Code in headless mode, whose report has
`usage`, `num_turns`, `total_cost_usd` and `duration_ms`. Another agent
needs a wrapper that prints those keys.

The default command lets the agent run anything without asking, which is
what an unattended build needs. Run this inside a disposable container or
VM, never on a machine whose files matter.
"""

import json
import os
import re
import shlex
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
TASKS = HERE / "tasks"
STACKS = HERE / "stacks"
RESULTS = HERE / "results"
DEFAULT_AGENT = ("claude -p --output-format json --max-turns 80 "
                 "--dangerously-skip-permissions")
BUILD_TIMEOUT = 300    # seconds for start.sh to build and bind
AGENT_TIMEOUT = 3600   # seconds for the agent to finish


def task_names():
    return sorted(p.name for p in TASKS.iterdir() if (p / "SPEC.md").exists())


def stack_names():
    return sorted(p.stem for p in STACKS.glob("*.md"))


def prompt_for(task, stack):
    parts = [(TASKS / task / "SPEC.md").read_text(),
             (TASKS / "COMMON.md").read_text(),
             "## Stack\n\n" + (STACKS / (stack + ".md")).read_text()]
    return "\n\n".join(p.strip() for p in parts) + "\n"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_for_port(port, proc, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if proc.poll() is not None:
            return False
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.25)
    return False


def start_service(workdir, port, log):
    """start.sh in its own process group, so stopping it stops everything
    it started (a build tool, a server it execs, a child it spawns)."""
    env = dict(os.environ, PORT=str(port))
    return subprocess.Popen(["sh", "start.sh"], cwd=workdir, env=env,
                            stdout=log, stderr=subprocess.STDOUT,
                            start_new_session=True)


def stop(proc):
    if proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(timeout=10)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def accept(task, port, out_path):
    env = dict(os.environ, PORT=str(port))
    r = subprocess.run([sys.executable, str(TASKS / task / "accept.py")],
                       env=env, capture_output=True, text=True, timeout=120)
    out_path.write_text(r.stdout + r.stderr)
    return r.returncode == 0


def _http_json(url, method="GET", data=None, headers=None):
    req = urllib.request.Request(url, data=data, method=method)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _perf_path(task, base):
    if task == "auth":
        return "/health"
    if task == "notes":
        return "/notes"
    if task == "ratelimit":
        return "/ping"
    if task == "jobs":
        body = json.dumps({"n": 10, "delay_ms": 0}).encode("utf-8")
        res = _http_json(f"{base}/jobs", method="POST", data=body,
                         headers={"Content-Type": "application/json"})
        jid = res["id"]
        for _ in range(40):
            st = _http_json(f"{base}/jobs/{jid}")
            if st.get("status") == "done":
                break
            time.sleep(0.05)
        return f"/jobs/{jid}"
    if task == "upload":
        boundary = "----slangbenchboundary"
        payload = (
            f"--{boundary}\r\n"
            'Content-Disposition: form-data; name="file"; filename="bench.txt"\r\n'
            "Content-Type: application/octet-stream\r\n\r\n"
            "hello agent benchmark\r\n"
            f"--{boundary}--\r\n"
        ).encode("utf-8")
        res = _http_json(
            f"{base}/files",
            method="POST",
            data=payload,
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        )
        return f"/files/{res['id']}"
    return None


def _to_ms(val, unit):
    v = float(val)
    if unit == "us":
        return v / 1000.0
    if unit == "ms":
        return v
    if unit == "s":
        return v * 1000.0
    if unit == "m":
        return v * 60000.0
    return v


def _pgid_rss_kb(pgid):
    r = subprocess.run(["ps", "-axo", "pgid=,rss="],
                       capture_output=True, text=True, timeout=5)
    if r.returncode != 0:
        return 0
    total = 0
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        try:
            if int(parts[0]) == pgid:
                total += int(parts[1])
        except ValueError:
            pass
    return total


def perf_bench(task, port, pgid, out_path):
    """Run short wrk HTTP load test and sample peak RSS (in MB) across pgid."""
    if not shutil.which("wrk"):
        return {}
    base = f"http://127.0.0.1:{port}"
    try:
        path = _perf_path(task, base)
    except Exception as exc:
        out_path.write_text(f"perf setup failed: {exc}\n")
        return {}
    if not path:
        return {}

    stop_evt = threading.Event()
    peak_kb = [_pgid_rss_kb(pgid)]

    def poll_rss():
        while not stop_evt.is_set():
            kb = _pgid_rss_kb(pgid)
            if kb > peak_kb[0]:
                peak_kb[0] = kb
            stop_evt.wait(0.15)

    t = threading.Thread(target=poll_rss, daemon=True)
    t.start()
    try:
        r = subprocess.run(
            ["wrk", "-t2", "-c32", "-d5s", "--latency", base + path],
            capture_output=True, text=True, timeout=30,
        )
    finally:
        stop_evt.set()
        t.join(timeout=2)

    out_path.write_text(r.stdout + r.stderr)
    if r.returncode != 0:
        return {}
    m_rps = re.search(r"Requests/sec:\s*([0-9.]+)", r.stdout)
    m_p99 = re.search(r"^\s*99%\s+([0-9.]+)(us|ms|s|m)\b",
                      r.stdout, re.MULTILINE)
    res = {}
    if m_rps:
        res["rps"] = round(float(m_rps.group(1)), 1)
    if m_p99:
        res["p99_ms"] = round(_to_ms(m_p99.group(1), m_p99.group(2)), 2)
    if peak_kb[0] > 0:
        res["peak_rss_mb"] = round(peak_kb[0] / 1024.0, 2)
    return res


def one_run(outdir, task, stack, agent_cmd, perf=True):
    work = outdir / "work"
    work.mkdir(parents=True)
    prompt = prompt_for(task, stack)
    (outdir / "prompt.md").write_text(prompt)
    t0 = time.time()
    with open(outdir / "agent.json", "w") as out, \
         open(outdir / "agent.err", "w") as err:
        try:
            subprocess.run(shlex.split(agent_cmd), cwd=work, input=prompt,
                           stdout=out, stderr=err, text=True,
                           timeout=AGENT_TIMEOUT)
        except subprocess.TimeoutExpired:
            err.write("\nagent timed out after %ds\n" % AGENT_TIMEOUT)
    agent_s = time.time() - t0
    verdict, why = False, ""
    perf_metrics = {}
    if not (work / "start.sh").exists():
        why = "no start.sh"
    else:
        port = free_port()
        with open(outdir / "server.log", "w") as log:
            proc = start_service(work, port, log)
            try:
                if not wait_for_port(port, proc, BUILD_TIMEOUT):
                    why = "service did not start"
                else:
                    verdict = accept(task, port, outdir / "accept.txt")
                    why = "" if verdict else "acceptance failed"
                    if verdict and perf:
                        perf_metrics = perf_bench(
                            task, port, proc.pid, outdir / "wrk.txt")
            finally:
                stop(proc)
    rec = {"task": task, "stack": stack, "pass": verdict, "why": why,
           "agent_seconds": round(agent_s, 1), "dir": str(outdir)}
    rec.update(read_report(outdir / "agent.json"))
    rec.update(perf_metrics)
    return rec


def read_report(path):
    """Tokens, turns, cost and model from the agent's report."""
    try:
        j = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    u = j.get("usage") or {}
    u_in = (u.get("input_tokens", 0) + u.get("cache_creation_input_tokens", 0)
            + u.get("cache_read_input_tokens", 0))
    u_out = u.get("output_tokens", 0)
    models = j.get("modelUsage") or {}
    mu_in = 0
    mu_out = 0
    model = None
    if isinstance(models, dict):
        for k, v in models.items():
            if not isinstance(v, dict):
                continue
            if model is None:
                model = v.get("canonicalModel") or k
            mu_in += (v.get("inputTokens", 0)
                      + v.get("cacheCreationInputTokens", 0)
                      + v.get("cacheReadInputTokens", 0))
            mu_out += v.get("outputTokens", 0)
    # Claude Code's top-level `usage` only covers the final turn sequence after
    # an interrupted wait, whereas `modelUsage` tracks the full session totals.
    if mu_in + mu_out > u_in + u_out:
        inp, out_tok = mu_in, mu_out
    else:
        inp, out_tok = u_in, u_out
    out = {"input_tokens": inp, "output_tokens": out_tok,
           "total_tokens": inp + out_tok,
           "turns": j.get("num_turns"), "cost_usd": j.get("total_cost_usd")}
    if model:
        out["model"] = model
    return out


def cmd_run(args):
    tasks = [args.task] if args.task else task_names()
    stacks = [args.stack] if args.stack else stack_names()
    agent_cmd = os.environ.get("AGENT_CMD", DEFAULT_AGENT)
    done = set()
    if args.resume:
        root = Path(args.resume)
        root.mkdir(parents=True, exist_ok=True)
        res_file = root / "results.jsonl"
        if res_file.exists():
            kept = []
            for l in open(res_file):
                if not l.strip():
                    continue
                r = json.loads(l)
                if r.get("turns") is not None:
                    kept.append(r)
                    done.add((r["task"], r["stack"], r.get("run", 1)))
            res_file.write_text("".join(json.dumps(r) + "\n" for r in kept))
        if not (root / "agent_cmd.txt").exists():
            (root / "agent_cmd.txt").write_text(agent_cmd + "\n")
    else:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        root = RESULTS / stamp
        root.mkdir(parents=True)
        (root / "agent_cmd.txt").write_text(agent_cmd + "\n")
    with open(root / "results.jsonl", "a") as res:
        # Interleaved (run, task, stack), so drift in the agent's service
        # over the session lands on every stack alike.
        for run in range(1, args.runs + 1):
            for task in tasks:
                for stack in stacks:
                    if (task, stack, run) in done:
                        continue
                    outdir = root / task / stack / str(run)
                    if outdir.exists():
                        shutil.rmtree(outdir)
                    rec = one_run(outdir, task, stack, agent_cmd)
                    rec["run"] = run
                    res.write(json.dumps(rec) + "\n")
                    res.flush()
                    print("%-10s %-12s run %d: %s %s tokens=%s turns=%s rps=%s rss=%s" % (
                        task, stack, run, "PASS" if rec["pass"] else "FAIL",
                        rec["why"], rec.get("total_tokens"), rec.get("turns"),
                        rec.get("rps", "-"), rec.get("peak_rss_mb", "-")))
    print("\nresults: %s" % root)
    summarize(root)


def summarize(root, markdown=False):
    rows = [json.loads(l) for l in open(root / "results.jsonl") if l.strip()]
    groups = {}
    by_stack = {}
    for r in rows:
        groups.setdefault((r["task"], r["stack"]), []).append(r)
        by_stack.setdefault(r["stack"], []).append(r)
    med = lambda xs: statistics.median(xs) if xs else None
    fmt = lambda v, pat: "-" if v is None else (pat % v)
    if markdown:
        print("| Task | Stack | Pass | Total tokens | Output tokens | Turns | Cost (USD) | RPS | p99 (ms) | Peak RSS (MB) |")
        print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    else:
        print("%-10s %-12s %5s %9s %12s %9s %6s %8s %9s %8s %8s" % (
            "task", "stack", "runs", "pass", "tokens(med)", "out(med)",
            "turns", "cost", "rps", "p99(ms)", "rss(MB)"))
    for (task, stack), rs in sorted(groups.items()):
        passed = sum(1 for r in rs if r["pass"])
        tok = med([r["total_tokens"] for r in rs if r.get("total_tokens")])
        out = med([r["output_tokens"] for r in rs if r.get("output_tokens")])
        turns = med([r["turns"] for r in rs if r.get("turns")])
        cost = med([r["cost_usd"] for r in rs if r.get("cost_usd")])
        rps = med([r["rps"] for r in rs if r.get("rps") is not None])
        p99 = med([r["p99_ms"] for r in rs if r.get("p99_ms") is not None])
        rss = med([r["peak_rss_mb"] for r in rs if r.get("peak_rss_mb") is not None])
        if markdown:
            print("| %s | %s | %d/%d | %s | %s | %s | %s | %s | %s | %s |" % (
                task, stack, passed, len(rs),
                fmt(tok, "%.0f"), fmt(out, "%.0f"), fmt(turns, "%g"),
                fmt(cost, "$%.2f"), fmt(rps, "%.0f"), fmt(p99, "%.2f"),
                fmt(rss, "%.1f")))
        else:
            print("%-10s %-12s %5d %4d/%-4d %12s %9s %6s %8s %9s %8s %8s" % (
                task, stack, len(rs), passed, len(rs),
                fmt(tok, "%.0f"), fmt(out, "%.0f"), fmt(turns, "%g"),
                fmt(cost, "$%.2f"), fmt(rps, "%.0f"), fmt(p99, "%.2f"),
                fmt(rss, "%.1f")))
    print("")
    if markdown:
        print("| Stack | Tasks passed | Median tokens | Median out | Median turns | Total cost (USD) | Median RPS | Median p99 (ms) | Median RSS (MB) |")
        print("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    else:
        print("%-12s %6s %12s %9s %6s %9s %9s %8s %8s" % (
            "stack", "pass", "tokens(med)", "out(med)", "turns",
            "tot_cost", "rps(med)", "p99(ms)", "rss(MB)"))
    for stack, rs in sorted(by_stack.items()):
        passed = sum(1 for r in rs if r["pass"])
        passing_rows = [r for r in rs if r["pass"]]
        tok = med([r["total_tokens"] for r in passing_rows if r.get("total_tokens")])
        out = med([r["output_tokens"] for r in passing_rows if r.get("output_tokens")])
        turns = med([r["turns"] for r in passing_rows if r.get("turns")])
        cost = sum(r["cost_usd"] for r in rs if r.get("cost_usd") is not None)
        rps = med([r["rps"] for r in passing_rows if r.get("rps") is not None])
        p99 = med([r["p99_ms"] for r in passing_rows if r.get("p99_ms") is not None])
        rss = med([r["peak_rss_mb"] for r in passing_rows if r.get("peak_rss_mb") is not None])
        if markdown:
            print("| %s | %d/%d | %s | %s | %s | $%.2f | %s | %s | %s |" % (
                stack, passed, len(rs),
                fmt(tok, "%.0f"), fmt(out, "%.0f"), fmt(turns, "%g"),
                cost, fmt(rps, "%.0f"), fmt(p99, "%.2f"), fmt(rss, "%.1f")))
        else:
            print("%-12s %2d/%-3d %12s %9s %6s %9s %9s %8s %8s" % (
                stack, passed, len(rs),
                fmt(tok, "%.0f"), fmt(out, "%.0f"), fmt(turns, "%g"),
                "$%.2f" % cost, fmt(rps, "%.0f"), fmt(p99, "%.2f"),
                fmt(rss, "%.1f")))


def cmd_summary(args):
    root = Path(args.dir) if args.dir else max(RESULTS.iterdir())
    summarize(root, markdown=args.md)


def cmd_selftest(args):
    """Each acceptance test must pass against its reference server, and
    must fail against another task's, so it is known to test something."""
    bad = 0
    names = task_names()
    for i, task in enumerate(names):
        for target, want in ((task, True), (names[(i + 1) % len(names)], False)):
            port = free_port()
            env = dict(os.environ, PORT=str(port))
            proc = subprocess.Popen([sys.executable, target + ".py"],
                                    cwd=HERE / "reference", env=env,
                                    stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL,
                                    start_new_session=True)
            try:
                if not wait_for_port(port, proc, 10):
                    print("FAIL reference %s did not start" % target)
                    bad = 1
                    continue
                got = subprocess.run(
                    [sys.executable, str(TASKS / task / "accept.py")],
                    env=env, capture_output=True, timeout=60).returncode == 0
            finally:
                stop(proc)
            if got != want:
                print("FAIL %s against the %s reference: %s" % (
                    task, target, "passed" if got else "failed"))
                bad = 1
    # The runner itself, end to end, with an agent that spends nothing.
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        fake = "%s %s" % (shlex.quote(sys.executable),
                          shlex.quote(str(HERE / "reference" / "fake_agent.py")))
        rec = one_run(Path(tmp) / "run", "notes", stack_names()[0], fake,
                      perf=False)
        if not (rec["pass"] and rec.get("total_tokens") == 1700
                and rec.get("turns") == 7):
            print("FAIL runner with the fake agent: %r" % rec)
            bad = 1
    print("selftest %s" % ("FAILED" if bad else "ok: every test passes its "
                           "reference and fails another's, and the runner "
                           "passes a fake agent's build"))
    return bad


def main():
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--task", choices=task_names())
    r.add_argument("--stack", choices=stack_names())
    r.add_argument("--runs", type=int, default=3)
    r.add_argument("--resume", help="resume an existing results directory, skipping completed runs")
    s = sub.add_parser("summary")
    s.add_argument("dir", nargs="?")
    s.add_argument("--md", action="store_true", help="output markdown tables")
    sub.add_parser("selftest")
    args = ap.parse_args()
    if args.cmd == "run":
        cmd_run(args)
    elif args.cmd == "summary":
        cmd_summary(args)
    else:
        sys.exit(cmd_selftest(args))


if __name__ == "__main__":
    main()
