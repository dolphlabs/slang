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
import shlex
import signal
import socket
import statistics
import subprocess
import sys
import time
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


def one_run(outdir, task, stack, agent_cmd):
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
            finally:
                stop(proc)
    rec = {"task": task, "stack": stack, "pass": verdict, "why": why,
           "agent_seconds": round(agent_s, 1), "dir": str(outdir)}
    rec.update(read_report(outdir / "agent.json"))
    return rec


def read_report(path):
    """Tokens and turns from the agent's report; empty if it has none."""
    try:
        j = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    u = j.get("usage") or {}
    inp = (u.get("input_tokens", 0) + u.get("cache_creation_input_tokens", 0)
           + u.get("cache_read_input_tokens", 0))
    return {"input_tokens": inp, "output_tokens": u.get("output_tokens", 0),
            "total_tokens": inp + u.get("output_tokens", 0),
            "turns": j.get("num_turns"), "cost_usd": j.get("total_cost_usd")}


def cmd_run(args):
    tasks = [args.task] if args.task else task_names()
    stacks = [args.stack] if args.stack else stack_names()
    agent_cmd = os.environ.get("AGENT_CMD", DEFAULT_AGENT)
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
                    outdir = root / task / stack / str(run)
                    rec = one_run(outdir, task, stack, agent_cmd)
                    rec["run"] = run
                    res.write(json.dumps(rec) + "\n")
                    res.flush()
                    print("%-10s %-12s run %d: %s %s tokens=%s turns=%s" % (
                        task, stack, run, "PASS" if rec["pass"] else "FAIL",
                        rec["why"], rec.get("total_tokens"), rec.get("turns")))
    print("\nresults: %s" % root)
    summarize(root)


def summarize(root):
    rows = [json.loads(l) for l in open(root / "results.jsonl") if l.strip()]
    groups = {}
    for r in rows:
        groups.setdefault((r["task"], r["stack"]), []).append(r)
    med = lambda xs: statistics.median(xs) if xs else None
    print("%-10s %-12s %5s %9s %12s %9s %6s %8s" % (
        "task", "stack", "runs", "pass", "tokens(med)", "out(med)",
        "turns", "cost"))
    for (task, stack), rs in sorted(groups.items()):
        passed = sum(1 for r in rs if r["pass"])
        tok = med([r["total_tokens"] for r in rs if r.get("total_tokens")])
        out = med([r["output_tokens"] for r in rs if r.get("output_tokens")])
        turns = med([r["turns"] for r in rs if r.get("turns")])
        cost = med([r["cost_usd"] for r in rs if r.get("cost_usd")])
        print("%-10s %-12s %5d %4d/%-4d %12s %9s %6s %8s" % (
            task, stack, len(rs), passed, len(rs),
            "-" if tok is None else "%.0f" % tok,
            "-" if out is None else "%.0f" % out,
            "-" if turns is None else "%g" % turns,
            "-" if cost is None else "$%.2f" % cost))


def cmd_summary(args):
    root = Path(args.dir) if args.dir else max(RESULTS.iterdir())
    summarize(root)


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
        rec = one_run(Path(tmp) / "run", "notes", stack_names()[0], fake)
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
    s = sub.add_parser("summary")
    s.add_argument("dir", nargs="?")
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
