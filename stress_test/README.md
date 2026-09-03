# Slang comprehensive stress suite

Stress tests Slang across the two things the language targets — server-side
HTTP and raw network I/O — plus a third dimension network testing alone
can't isolate: how many simultaneously-alive concurrent tasks the M:N
scheduler and GC can actually carry, with no network in the way at all.

See `reports/stress_report.html` for the full write-up (request-count
scaling 10k-100k, concurrency scaling, per-endpoint characterization, a
breaking-point probe, a soak test, CPU profiles, and the concurrent-task
scaling curve, each with real charts built from a real run) — also
published at https://claude.ai/code/artifact/152816e9-0334-4c76-a833-9f20e1473ff3.
Twelve phases, one continuous run, zero server crashes across HTTP, raw
TCP, and pure concurrent-compute.

**Known-fixed issue, kept here as a record rather than silently dropped:**
an earlier run had two real bugs — the HTTP phases pointed at the wrong
port (100% client errors, not a server fault) and the request-count/
concurrency TCP phases churned a fresh connection per round-trip, which
silently ran into macOS's own ~16,384 ephemeral-port ceiling well before
the server was ever the constraint (confirmed directly: it reproduced
even at concurrency 10). Both fixed — the port now matches
`demo/stress_harness/scenarios/*.json`'s own hardcoded `8095`, and
scaling phases dial once per worker and ride many round-trips on that
connection (`tcp_loadgen.go`'s `-persistent` flag) instead of reconnecting
every time; connection-churn behavior itself is still measured, just as
its own separate, bounded phase (see "Load generators" below). A third,
separate issue — the concurrent-task-stress phase occasionally producing
zero output files despite the script reporting all phases complete, root
cause never pinned down despite dedicated live investigation — did **not**
reproduce on the run this report is built from; flagged here in case it
resurfaces, not because it's currently blocking anything.

## Targets

- **HTTP**: `demo/main.sl`, the Arcade demo server already used throughout
  the project's own Tier 9-11 acceptance testing — reused rather than
  reimplemented, since it already exercises `net`/`chan`/`spawn`/`json`
  under real routing.
- **Raw TCP**: `programs/tcp_echo/main.sl` — a new, real echo server
  (single accept-loop task, worker pool over `chan[i32]`, no HTTP framing
  at all), so `net.*`/the kqueue reactor get stress-tested on their own
  terms.
- **Concurrent compute**: `programs/concurrent_compute/main.sl` — no
  network at all. Spawns a configurable number of tasks, each doing real
  CPU work (prime counting) plus allocation (list/map building), and
  reports aggregate throughput. Isolates the scheduler/GC's own cost from
  `net.*`'s.

## Quick start

```sh
cd stress_test/scripts
./run_full_suite.sh
```

Builds everything (slangc, the three stress targets, both load
generators) and runs the full matrix — roughly 23-25 minutes end to end
(twelve phases; the original 15-minute estimate was from an earlier,
smaller matrix).
Results land in `results/*.json` / `*.csv` / `*.txt`, gitignored (fresh
data every run, not meant to be committed).

## Load generators

- `demo/stress_harness/loadgen` — the project's existing Go HTTP load
  generator, extended here with an exact `-requests N` stop condition
  (the existing tool was duration-based only).
- `scripts/tcp_loadgen.go` — new. Two modes: default (fresh connection
  per round-trip — real, but bounded by the OS's own ephemeral port
  range under sustained churn) and `-persistent` (one connection per
  worker, many round-trips on it — the scaling-safe mode, and the more
  realistic shape for steady-state throughput). See the report's "Raw
  TCP" section for the exact failure this was built to work around.

## Directory structure

```
programs/    # real, working .sl programs, one per subdirectory
             # (the loader treats a directory as a package -- never
             # put two independent programs' .sl files side by side)
scripts/     # run_full_suite.sh, monitor.sh (RSS/CPU sampling),
             # tcp_loadgen.go
results/     # raw output from the last run (gitignored)
reports/     # stress_report.html -- the published analysis
```
