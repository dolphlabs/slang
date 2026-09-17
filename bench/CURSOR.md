# Running the benchmark suite (for the Cursor remote-host session)

You are picking up work already done in this repo, on branch `bench/suite`.
This file is the handoff: what exists, what to run, and exactly how to give
the result back so it can be folded into the README and docs. Read
`bench/SPEC.md` first — it is the contract every implementation satisfies.
This file is the operator's guide to executing that contract.

## What's already built

- `bench/SPEC.md` — the spec: languages, workloads, endpoints, SQL, load
  profiles, response contracts, and the fixed stack per language.
- `bench/suite/setup_host.sh` — provisions a bare Ubuntu 24.04 box: pinned
  Go/Rust/.NET/JDK/Python/Node/Bun, Postgres 16 tuned for this workload,
  wrk + wrk2, sysctl/ulimit tuning, CPU governor.
- `bench/suite/langs.sh` — how every one of the 9 languages is built and
  started. Single source of truth for compiler/runtime flags.
- `bench/suite/db/` — schema, deterministic seed (`schema.sql`, `seed.sql`,
  `reset.sql`), and `postgresql.bench.conf`.
- `bench/suite/data/gen_batch.c` — deterministic CSV generator for the batch
  workload (splitmix64, so every language gets byte-identical input).
- `bench/suite/lib/` — `conformance.py` (correctness gate), `sampler.py`
  (RSS/CPU sampler), `batch_reference.py` + `gen_quote.py` (oracles/fixtures),
  `report.py` (aggregates a run into `results.json` + `summary.md`), Lua
  scripts for wrk/wrk2 (`common.lua`, `point.lua`, `quote.lua`, `mix.lua`).
- `bench/suite/api/*`, `bench/suite/batch/*`, `bench/suite/light/*` — the 9
  implementations of the heavy API service, the heavy batch job, and the
  light http/compute workloads. (`bench/http/*` and `bench/compute/*` at the
  repo root are older, simpler light-tier implementations kept for numeric
  continuity with earlier ad-hoc results; `langs.sh` uses those for Go/Rust/C
  and the new `bench/suite/light/*` ones for Java/Python/Bun/Node/C#, since
  the old Java/C# servers there were not performance-tuned.)
- `bench/suite/run.sh` — orchestrates everything end to end.

All nine languages passed the API conformance gate and the batch 1M-row
correctness check locally (Darwin/Linux container, WORKERS 1-4), including
C#'s three programs (api, batch, light/http), built and run against
.NET SDK 10 in a container. The full suite has **not** yet been run
end-to-end at full scale — that's what this remote host is for. Two known,
unfixed findings from local testing that are not blockers, but are worth
keeping in mind when you read slang's numbers (see "Known findings" below).

## 1. Provision the host

Pick a dedicated bare-metal or a large dedicated-core cloud instance —
**not** a burstable/shared-vCPU instance; the CPU pinning this suite relies
on is meaningless if the hypervisor is also scheduling other tenants onto
the same physical cores. Ubuntu 24.04 x86_64, 16+ cores, 32GB+ RAM for a
`QUICK=1` smoke run; for the full-scale heavy tier (1M users / 20M orders in
Postgres, a 100M-row / ~5-6GB batch CSV) budget 64GB+ RAM and fast local
NVMe (Postgres and the batch file both want real disk throughput, not
network-attached storage with variable latency).

```sh
git clone <this repo> && cd slang
git checkout bench/suite
sudo bench/suite/setup_host.sh
```

Re-run it if it fails partway — it's idempotent. It prints installed
versions at the end and tells you to log out/in once (for the raised
`nofile` limit to apply to your login shell).

## 2. Smoke test first

Always run `QUICK=1` before the full run. It uses a tiny dataset (20K
users / 400K orders, a 2M-row batch file), short durations, and 1 round, and
still exercises every phase: build, seed, conformance, light tier, heavy
tier, batch, report. It should finish in well under 10 minutes on a decent
box.

```sh
QUICK=1 bench/suite/run.sh
```

Check `bench/results/<run id>/correctness.json` — every language should be
`"pass"` for every workload. If a language fails to build or fails
conformance, **do not silently exclude it**: see "Rules for this run" below.

If you want to iterate on just a subset while debugging:

```sh
QUICK=1 LANGS="slang go c python" TIERS=light bench/suite/run.sh
```

## 3. Full run

```sh
ROUNDS=3 bench/suite/run.sh
```

This is a long run (expect a few hours: seeding 1M/20M rows, generating a
100M-row batch file, then light + heavy tiers × 3 rounds × 9 languages, with
warmups). `run.sh` logs progress to `bench/results/<run id>/run.log` and
`stdout` as it goes — if your session can be interrupted, run it under
`tmux`/`screen`/`nohup` so it survives a dropped connection:

```sh
tmux new -s bench
ROUNDS=3 bench/suite/run.sh
# Ctrl-B D to detach; tmux attach -t bench to check back in
```

Useful overrides (see the top of `run.sh` for the full list): `LANGS`,
`TIERS=light` / `TIERS=heavy`, `SERVER_CPUS` / `LOADGEN_CPUS` / `DB_CPUS` to
override the automatic CPU split, `ROUNDS`.

## Rules for this run

1. **Don't tune or rewrite an implementation to make it faster**, beyond
   what's needed to make it build/run/pass conformance on this host (e.g. a
   missing system package, a path that doesn't exist on Linux, a version
   bump because a pinned dependency no longer resolves). `langs.sh` and
   `bench/SPEC.md`'s implementation table are the source of truth for what
   stack each language uses — if you change a flag or a dependency version
   to get something working, **update both** and note it in your report (see
   below).
2. **A language that fails to build or fails conformance stays in the run**
   as failed — don't drop it from `LANGS`. `report.py` records it under
   `results.json.correctness` and lists it in `summary.md` under "Failed and
   not measured"; that's the correct outcome, not something to work around.
3. **Don't hand-edit `bench/results/<run id>/`** — it's entirely generated
   by `run.sh` and `report.py`. If a number looks wrong, fix the harness and
   re-run, don't patch the JSON.
4. Zig is explicitly **out of scope** — it was dropped from this suite.

## Known findings from local testing (not blockers, just context)

- **(fixed during harness smoke-testing)** An earlier draft of this suite had
  a real bug, not a slang runtime issue: `langs.sh` only ever exported
  `SLANG_WORKERS` (the runtime's green-thread scheduler pool size) when
  starting slang's `api` and `batch` programs, but `bench/suite/api/slang/main.sl`
  and `bench/suite/batch/slang/main.sl` read their own app-level concurrency
  (accept-loop count, CSV worker count) from a plain `WORKERS` env var that
  was never set — so slang's API server always ran with a single acceptor
  loop and the batch job always used its hardcoded default of 8 workers,
  regardless of how many cores the harness allotted. This is why an earlier
  local test saw slang's heavy/api throughput collapse (~150 req/s against
  4 allotted cores, saturating all 4 anyway) and batch show no scaling
  between 1 and 8 workers — both were artifacts of the app never seeing the
  real worker count. `langs.sh` now sets `WORKERS=$WORKERS` alongside
  `SLANG_WORKERS=$WORKERS` for both. If slang's numbers still look
  disproportionately slow on the full run after this fix, that's a genuine
  runtime finding worth its own issue — but don't assume it without
  re-checking this env var is actually reaching the process (`server.log`
  or a quick `ps aux` while a round is running).
- **slang's servers don't exit on SIGTERM** — `run.sh`'s `stop_server`
  sends TERM then, after a grace period, KILL, so this doesn't break the
  run. It's listed here so a slower-than-expected teardown between rounds
  for slang isn't mistaken for a harness bug.
- **slang's `pg` driver defaults to `sslmode=require` for any non-loopback
  host** (a deliberate secure default — see `stdlib/pg/pg.sl`). The default
  `DATABASE_URL` in `run.sh` (`127.0.0.1`) is loopback, so this doesn't come
  up in normal use. It only matters if you point `DATABASE_URL` at a
  Postgres on a different host without TLS configured — add
  `?sslmode=disable` to the URL in that case (or, better, configure TLS on
  Postgres). Every other language's driver in this suite is more permissive
  by default, so this is slang-specific behavior, not a bug.

## 4. Deliver the results

When `run.sh` completes (or you stop it after a partial run you want
recorded), commit the **entire** `bench/results/<run id>/` directory:

```
bench/results/<run id>/
  env.json          host info, git sha, config (cpu split, rounds, durations)
  builds.json        per-language build ok/fail + build time
  correctness.json   per-language, per-workload conformance pass/fail + detail
  runs.jsonl         one JSON line per measurement, with a pointer to its raw log
  raw/                every wrk/wrk2 log and resource-sample file runs.jsonl points to
  results.json        schema "slang-bench/1" — see below
  summary.md           human-readable tables, generated by lib/report.py
  run.log
```

Push it on a **new branch off `dev`** (per this repo's normal workflow —
one branch per task, PR into `dev`, never stack on top of another open PR)
and open a PR. Suggested branch name: `bench/results-<run id>`. In the PR
description:

- The host spec (CPU model, core count, RAM, disk) — `env.json` has most of
  this but say it in prose too.
- `ROUNDS`, `TIERS`, and whether it was a full-scale or `QUICK` run.
- Any deviation from rule 1 above (a dependency bump, a flag change to get
  something to build) — file, what changed, why.
- Any language that failed to build or failed conformance, and why if known.
- Total wall-clock time the run took.

Paste `summary.md` into the PR body so the numbers are visible without
opening files.

### `results.json` schema (`slang-bench/1`)

This is what should get picked up to update the README/docs, so the shape
matters:

```jsonc
{
  "schema": "slang-bench/1",
  "env": { /* host, git sha, cpu split, config — from env.json */ },
  "builds": { "<lang>": { "ok": true, "build_ms": 1234 }, ... },
  "correctness": { "<workload>": { "<lang>": { "status": "pass"|"fail", "detail": "" } } },
  "summary": [
    {
      "tier": "light"|"heavy", "workload": "http"|"compute"|"api"|"batch",
      "scenario": "...", "lang": "...", "rounds": 3,
      "tool": "wrk"|"wrk2"?, "connections": 64?, "rate": 2000?,
      "rps": 12345.6?, "error_rate": 0.0?,
      "latency_ms": { "p50": ..., "p90": ..., "p99": ..., "p99_9": ..., "max": ... }?,
      "wall_ms": ...?, "tasks_per_sec": ...?,
      "peak_rss_mb": ..., "avg_cpu_cores": ..., "cpu_seconds": ...,
      "db_avg_cpu_cores": ...?,           // api only
      "all_rounds_agree": true?           // batch only: output hash matches majority
    },
    ...
  ],
  "measurements": [ /* every individual (round, scenario, connections/rate) data point, same shape, pre-median */ ]
}
```

`summary` is the median across `rounds` for each
`(tier, workload, scenario, tool, connections, rate, lang)` group — that's
what should drive README/docs numbers. `measurements` is the full
unaggregated data, kept for anyone who wants to check variance across
rounds or re-slice it differently.

### What I'll do once I have this

When you hand back the PR (or just the `results.json` / `summary.md` if
that's faster), I'll read `results.json`, cross-check `correctness` and
`builds` for anything that failed, and update:

- The README's performance section with the headline light + heavy numbers
  and a link to the full `summary.md`.
- Any docs page that currently has stale or placeholder benchmark numbers.
- A short note on the two known findings above if the full run confirms
  them at scale (slang batch scaling, SIGTERM handling), since those are
  runtime bugs worth their own follow-up issues, not just benchmark trivia.

If anything in `results.json` looks inconsistent with `correctness.json` or
`builds.json` (e.g. a language marked "pass" with suspiciously fast/slow
numbers, or missing rounds), flag it in the PR description rather than
letting me guess — I don't have access to the host that produced the raw
logs.
