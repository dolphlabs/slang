# Targeted Go and Slang PostgreSQL benchmark

## Objective

Measure the PostgreSQL-backed API paths in Slang and Go on one new, isolated
VPS without building or running the rest of the language suite. The run should
show throughput, tail latency, pool acquisition, client query/result handling,
PostgreSQL execution, and process resource use for each route. Its output will
guide the next optimization; it is not an optimization or a claim of parity.

## Evidence and question

The 2026-10-09 32-vCPU run measured Slang at 2.4%–7.4% of Go on `/point` and
`/mix`, while PostgreSQL used less than one Slang-run CPU core and 5–8 Go-run
cores. Aggregate CPU does not distinguish pool acquisition, driver/result
handling, or server execution, and does not establish mutex contention. The
route timing probe in PR #368 separates those stages and is required for this
run.

## Host and database

- Ubuntu 24.04 x86_64, 4 vCPUs and 16 GB RAM, reserved for this benchmark.
- At least 20 GiB free where PostgreSQL stores data before seeding; a 40 GB
  or larger VPS disk leaves room for the seed, indexes and WAL.
- PostgreSQL 16, Go 1.24.1, and the Slang compiler built from the tested
  checkout. Record exact versions and the measured commit in the result.
- PostgreSQL and the API share CPUs 0–2. Pin the load generator to CPU 3 so
  its work does not compete with the API or database. Capture load-generator
  CPU use; a saturated generator invalidates that sample.
- Main seed: 1,000,000 users and 20,000,000 orders, matching the latest VPS
  run. Offer 20,000 users and 400,000 orders as a quick smoke configuration.
- Keep `DB_POOL_TOTAL=64` for continuity. Record steal time and host memory.
  Do not compare absolute results with the previous 32-vCPU machine.

## Workloads

Run each route independently, using the same route arguments for both
implementations:

| Route | Request |
|---|---|
| Point | `GET /api/users/7` |
| Orders | `GET /api/users/7/orders?limit=50` |
| Summary | `GET /api/users/7/summary` |
| Insert | `POST /api/orders` with `{"user_id":7,"sku":"SKU-00042","qty":2,"price_cents":1999}` |

Use HTTP keep-alive and 64 and 512 concurrent connections. Warm the exact route
before each sample so prepared statements and per-connection caches are warm.
Reset appended insert rows to the seeded maximum before every insert sample.
Run the existing API conformance checks for Go and Slang before measuring.

## Run order and measurements

Use three ABBA rounds for each route/concurrency pair. Round 1 is
Slang/Go/Go/Slang, round 2 is Go/Slang/Slang/Go, and round 3 returns to
Slang/Go/Go/Slang. Each sample runs for 15 seconds after a 5-second route
warmup. Reset `pg_stat_statements` after warmup and save before/after snapshots
for each sample.

Record per sample:

- Requests per second and p50/p90/p99/p99.9 latency from `latgen`.
- The response-header distributions for pool acquisition and client query,
  row decoding, and connection release, enabled with `PG_PROFILE=1`.
- `pg_stat_statements` calls, rows, total execution time, and mean execution
  time for the route SQL.
- API, PostgreSQL, and load-generator CPU time and peak RSS.
- HTTP/profile errors, correctness status, host steal time, and run order.

After warmup, each client sends one logical PostgreSQL request/response
exchange per route query by source inspection. The SQL execution count is
checked against completed route requests from PostgreSQL statistics. Packet
counts are not protocol round-trip counts and are out of scope.

## Validity and acceptance

The runner must refuse an occupied API port and a concurrent run, preserve raw
logs and snapshots, and stop only processes it started. Keep the VPS idle
except for PostgreSQL, the measured API, the pinned load generator, and the
samplers. Mark a sample invalid if the load generator saturates its reserved
core, CPU steal is material, correctness fails, or requests return unexpected
statuses.

The runner uses 0.95 load-generator CPU cores as the saturation limit and 2%
CPU steal as the host-noise limit. It validates response status, profile
header coverage, PostgreSQL query calls versus completed HTTP responses, and
captures separate API, PostgreSQL and load-generator CPU/RSS samples. If the
single-core generator saturates, the sample is invalid and its clipped RPS is
not used for a parity claim.

Report medians and all raw samples by route, language, and connection count.
The existing goal remains at least 98% of Go throughput for every route and
connection count, with p99 and RSS reported alongside it. A result outside
that gate remains an open performance gap; do not average routes together to
claim success.

## Out of scope

Do not benchmark Rust, Java, Node, quote, batch, raw HTTP, or the full suite.
The existing conformance check exercises quote only to verify both APIs; it is
not part of the measured workload. Do not alter SQL, pool size, route
semantics, or runtime code as part of this benchmark task. Select a code
optimization only after these measurements identify its cost center.

## Runbook and artifacts

The focused implementation is `bench/suite/run_pg_routes.sh`, with
`bench/suite/setup_pg_routes_host.sh` for the dedicated VPS and
`bench/suite/lib/pg_routes_report.py` for per-sample validation and reporting.
The installer pins Go 1.24.1 to the SHA-256 checksum published by the Go
downloads page, enables `pg_stat_statements`, restricts PostgreSQL to the
server CPUs, and listens on localhost only. It restarts PostgreSQL and sets
the local benchmark role password; use it only on the new benchmark machine.

On the VPS, check the workload plan first, then prepare and run:

```sh
bench/suite/run_pg_routes.sh --plan
sudo bench/suite/setup_pg_routes_host.sh
bench/suite/run_pg_routes.sh
```

The installer does not seed or drop benchmark tables. The runner creates and
seeds an empty `bench` database. It refuses to replace a mismatched non-empty
database unless `RESEED=1` is set explicitly. `SCALE=quick` selects the
20K-user / 400K-order smoke seed, one 64-client round, and short samples.
The full matrix has 96 measured samples (24 minutes of measurement plus
8 minutes of warmup, before seeding and correctness checks).

Each run is saved below `bench/results/pg-routes-<run id>/`: `env.json`
records the measured commit and host/toolchain, `raw/` retains every request
latency, API log, process sample and PostgreSQL snapshot, and `summary.md` plus
`results.json` report per-route medians and validity. Benchmark artifacts are
not committed automatically.
