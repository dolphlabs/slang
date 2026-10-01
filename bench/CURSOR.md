# Running the benchmark suite (operator's guide)

You are running the cross-language suite on a remote host, from branch
`dev`. This file covers what to provision, what to run, and how to hand the
results back so they can go into the README and docs. Read
`bench/SPEC.md` first: it is the contract every implementation satisfies.

## The run this guide is for

| | |
|---|---|
| Host | Hetzner Cloud **CCX33**: 8 dedicated AMD vCPU, 32 GB RAM, 240 GB local NVMe |
| Image | **Ubuntu 24.04** (not 26.04: `setup_host.sh` installs `postgresql-16`, which 24.04 ships) |
| Languages | **slang, Go, Rust, Java, Node** |
| Scale | full: 1M users / 20M orders in Postgres; batch 100M rows / 5M users |
| Rounds and durations | `ROUNDS=3`, `API_DUR=20s`, `WARMUP=10s`, `HTTP_DUR=15s` |
| Expected time | about 2h 15m, setup and the smoke test included |

Shared-vCPU types (Hetzner CPX) are out: the CPU pinning this suite relies
on means nothing when other tenants share the physical cores, and tail
latency becomes noise.

On 8 CPUs, `run.sh` splits them automatically: the server under test gets
cores 0-3 (`WORKERS=4`), the load generator 4-5 and Postgres 6-7. Keep that
in mind when reading results (see "Reading the results").

## What's already built

- `bench/SPEC.md`: languages, workloads, endpoints, SQL, load profiles,
  response contracts, and the fixed stack per language.
- `bench/suite/setup_host.sh`: provisions a bare Ubuntu 24.04 box with
  pinned Go/Rust/.NET/JDK/Python/Node/Bun, Postgres 16 tuned for this
  workload, wrk and wrk2, and sysctl/ulimit tuning. It installs every
  toolchain even when `LANGS` names fewer, which costs a few minutes.
- `bench/suite/langs.sh`: how each language is built and started; the
  single source of truth for compiler and runtime flags.
- `bench/suite/db/`: schema, deterministic seed, reset, and
  `postgresql.bench.conf` (4 GB shared buffers).
- `bench/suite/data/gen_batch.c`: deterministic CSV generator for batch.
- `bench/suite/lib/`: the conformance gate, RSS/CPU sampler, oracles,
  `report.py` (writes `results.json` and `summary.md`), and wrk Lua scripts.
- `bench/suite/run.sh`: runs everything end to end.

## 1. Provision the host

```sh
git clone https://github.com/dolphlabs/slang && cd slang
git checkout dev && git rev-parse HEAD      # record the sha
sudo bench/suite/setup_host.sh
```

It is idempotent: re-run it if it fails partway. It prints the installed
versions at the end; log out and back in once so the raised `nofile` limit
applies. Run everything after this inside `tmux` so a dropped connection
does not kill the run:

```sh
tmux new -s bench          # Ctrl-B D to detach; tmux attach -t bench to return
```

## 2. Smoke test first (~10 min)

```sh
QUICK=1 LANGS="slang go rust java node" bench/suite/run.sh
```

A tiny dataset, short durations, one round, but every phase: build, seed,
conformance, light tier, heavy tier, batch, report. Then check
`bench/results/<run id>/correctness.json`: every language must be `"pass"`
for every workload. If one is not, see the rules below; do not drop it.

## 3. Full run (~2 hours)

```sh
LANGS="slang go rust java node" ROUNDS=3 \
API_DUR=20s WARMUP=10s HTTP_DUR=15s bench/suite/run.sh
```

Where the time goes, from the harness's loops:

| phase | time |
|---|---|
| setup, builds, seeding 20M orders, generating the batch file | ~40 min |
| heavy api: 3 scenarios × (10 s warm-up + 4 × 20 s) × 5 languages × 3 rounds | ~67 min |
| light http + compute | ~11 min |
| batch, 100M rows, 5 languages × 3 rounds | ~15 min |

Progress goes to `bench/results/<run id>/run.log` and stdout. Other
overrides are listed at the top of `run.sh` (`TIERS`, `SERVER_CPUS` /
`LOADGEN_CPUS` / `DB_CPUS`).

**If batch runs out of memory** (32 GB with Postgres resident; Java runs
with `-Xmx12g`): re-run that tier with `TIERS=heavy` and
`BATCH_ROWS=50000000 BATCH_USERS=2500000`, and say so in the report.

## Rules for this run

1. **Don't tune or rewrite an implementation to make it faster**, beyond
   what it takes to build, run and pass conformance on this host (a missing
   package, a Linux path, a pinned dependency that no longer resolves). If
   you change a flag or a version, update `langs.sh` and SPEC.md's
   implementation table both, and list the change in the report.
2. **A language in `LANGS` that fails to build or fails conformance stays
   in the run as failed.** `report.py` lists it under "Failed and not
   measured". Don't remove it to make the run look clean.
3. **Don't hand-edit `bench/results/<run id>/`.** It is generated. If a
   number looks wrong, fix the harness and re-run.
4. **Only the five languages above were measured.** C#, Bun, Python and C
   are in the suite but not in this run: nothing from this run supports a
   claim about them.

## Reading the results

- **The load generator may be the ceiling.** wrk gets 2 cores. In light
  http and api point reads, several fast languages landing at the same
  req/s with cores 4-5 at 100% means wrk was the limit, not the servers.
  Say so rather than ranking them.
- **Postgres has 2 cores.** Point reads and the mix can be database-bound;
  `db_avg_cpu_cores` in `results.json` shows it.
- **slang, known costs** (`next-steps.md` §5b and §9, `todo.md`):
  - JSON-heavy work (`api/quote`, and the mix through it) is the largest
    gap: about 5.8x behind Go on the laptop, from per-object allocation and
    GC. Measuring it is the point; don't work around it.
  - One request/response round trip on one connection pays about 185 µs of
    park/wake in the runtime. Expect database point reads to trail Go and
    Rust by more than the CPU numbers suggest.
  - **slang's servers don't exit on SIGTERM** (`next-steps.md` §2).
    `run.sh` sends TERM, then KILL after a grace period, so the run is not
    affected; a slow teardown between rounds for slang is this, not a
    harness bug.
  - slang's `pg` driver requires TLS for any non-loopback host. The default
    `DATABASE_URL` is loopback; add `?sslmode=disable` only if you point it
    at another host without TLS.
- **Check the worker count reached slang** (`WORKERS` and `SLANG_WORKERS`
  in `ps eww` during a round) before calling a slang number slow.

## 4. Deliver the results

Commit the **entire** `bench/results/<run id>/` directory, for the smoke run
and the full run, on a new branch off `dev` named
`bench/results-<run id>`, and open a PR into `dev`:

```
bench/results/<run id>/
  env.json          host info, git sha, config (cpu split, rounds, durations)
  builds.json       per-language build ok/fail and build time
  correctness.json  per-language, per-workload conformance pass/fail
  runs.jsonl        one line per measurement, pointing at its raw log
  raw/              every wrk/wrk2 log and resource-sample file
  results.json      schema "slang-bench/1", below
  summary.md        tables generated by lib/report.py
  run.log
```

In the PR description:

- the host in prose (CCX33, CPU model from `env.json`, RAM, disk), the git
  sha, and the exact command line;
- total wall-clock time;
- every deviation from rule 1: file, change, reason;
- every language that failed to build or conformance, and why if known;
- anything inconsistent: a pass with implausible numbers, missing rounds,
  high variance across rounds, a load-generator or database ceiling;
- `summary.md`, pasted in full.

**Then delete the server.** A stopped Hetzner server is still billed; only
deleting it stops the charge. Make sure the results are pushed first.

### `results.json` schema (`slang-bench/1`)

This is what the README and docs are updated from, so the shape matters:

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
  "measurements": [ /* every (round, scenario, connections/rate) data point, same shape, pre-median */ ]
}
```

`summary` is the median across rounds for each
`(tier, workload, scenario, tool, connections, rate, lang)` group, and is
what README and docs numbers come from. `measurements` keeps every data
point for checking variance.

### What happens next

The PR's `results.json` is read and cross-checked against `correctness`
and `builds`, and then:

- the README's performance section gets the headline numbers, a link to
  `summary.md`, and the run's host and language set;
- the website shows the five measured languages only, with the date and
  host;
- any finding the run confirms at scale becomes its own follow-up item.

Flag anything that looks off in the PR description rather than leaving it
to be guessed: nobody else has access to the host's raw logs.
