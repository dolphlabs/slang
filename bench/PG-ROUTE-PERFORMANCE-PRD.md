# PostgreSQL Route Performance PRD

## Problem

The heavy API benchmark has four PostgreSQL-backed routes: point user lookup,
paginated orders, per-user summary, and order insert. Slang is competitive on
the raw HTTP/JSON quote route, but the database routes can fall behind Go,
especially under 512 concurrent connections. A single short diagnostic pass on
the current `origin/dev` source suggests the gap is not explained by extra
database round trips: each route makes one SQL call per request, and the slang
driver batches Parse/Bind/Describe/Execute/Sync into one extended-protocol
exchange. The diagnostic run is too short to serve as a performance claim and
must be repeated with ABBA ordering before choosing a fix.

## User and outcome

For a backend service handling real database work, Slang should deliver at
least 98% of Go's successful requests per second on every PostgreSQL-backed
API route at both 64 and 512 connections, measured on the same host and
database. This target applies separately to:

- `GET /api/users/{id}` (point lookup)
- `GET /api/users/{id}/orders?limit=50` (indexed list/search)
- `GET /api/users/{id}/summary` (aggregate)
- `POST /api/orders` (insert)

The improvement must preserve correct status codes and parsed JSON output,
keep p99 latency and peak RSS within the benchmark's measured run-to-run range
of Go, and avoid regressing the quote and mixed workloads beyond their run
spread. If any route remains outside the 2% target, report it as an unmet gate;
do not claim parity from an aggregate average.

## Project context

The benchmark API is an HTTP/1.1 JSON service with a 20,000-user and
400,000-order seeded PostgreSQL dataset in the current diagnostic environment.
Both implementations use a 64-connection pool, run on four pinned server
cores, and receive load from two pinned cores. The route SQL, request values,
response schema, and reset behavior are specified in `bench/SPEC.md`. The
Slang implementation uses `stdlib/pg` and the Go implementation uses pgx.

The first exact-dev smoke run used a five-second sample and Go 1.22 because
Go 1.23 was unavailable in the benchmark container. It showed strong
connection-pool waits at 512 clients for both implementations and higher
Slang server CPU on orders and summary, but the sample was too short and
sequential to identify a root cause. Treat it as diagnostic evidence only.

## Scope

Profile and optimize the measured PostgreSQL route path, including the Slang
PostgreSQL driver's protocol/result handling, HTTP request task scheduling,
and route response construction. Choose a code change only after the matched
ABBA profile attributes measurable cost to that layer.

The change must not alter the public API, SQL semantics, connection-pool
limits, dataset, benchmark route mix, or error behavior. Do not implement a
scheduler architecture redesign without a separate design review, as required
by `todo.md` R2.

## Measurement and acceptance

Run the current `origin/dev` and candidate builds in the guarded benchmark
containers, with the same PostgreSQL instance and Go toolchain. Use ABBA
ordering, at least three rounds per route and connection count, and enough
duration for stable medians. Record raw samples and report median requests/s,
p50/p99 latency, server CPU per request, peak RSS, PostgreSQL execution time
per query, pool wait count/time, SQL calls per request, and protocol exchanges
per request. Keep the quote and mixed scenarios as regression checks.

The final result passes only if every PostgreSQL route is at least 98% of Go
at both concurrency levels, the SQL-call and protocol-exchange counts remain
one per successful request, correctness/conformance passes, p99 and RSS do not
regress beyond the observed spread, and `make test` passes. Include raw
baseline and candidate values; if a gate cannot be met, state the measured
shortfall precisely.

## Risks and constraints

- The Mac-hosted Linux container is noisy; ABBA ordering and multiple rounds
  are required, and changes smaller than the spread are inconclusive.
- The installed Go command in the benchmark container is Go 1.22.2, but the
  exact comparison binary was verified with `go version -m` as Go 1.23.4 and
  its source matches the current suite API. Preserve this distinction when
  rebuilding or repeating the comparison.
- The benchmark database uses a small deterministic dataset, so any measured
  gain must be checked for changes to query plans and must not be generalized
  to the 1M-user production-scale dataset without a larger run.
- Any runtime change needs a failing-before/passing-after test, full tests,
  generated-C warning checks, GC stress where relevant, and a Linux arm64 CI
  dispatch as specified in `AGENTS.md`.

## Profile findings and current gate status (2026-10-09)

The measured implementation changes are deliberately limited to the driver
and JSON encoder: cached PostgreSQL statements request binary results for
integer, boolean, and bytea columns; text getters avoid an intermediate byte
slice; and JSON list/map encoders reserve an item-based output estimate.
An experiment storing API `Order` rows as plain values did not show a
repeatable win. Removing a duplicate row/column validation pass from
`get_text` also measured within noise and was dropped.

The guarded, clean-seed ABBA route samples below compare the candidate to the
Go 1.23.4 binary. They are two-round medians, so treat small deltas as inconclusive.
They do show that this candidate does **not** pass the 98% target at every
route/concurrency pair:

| Route | Clients | Slang RPS | Go RPS | Slang / Go |
|---|---:|---:|---:|---:|
| Point user | 64 | 19,355 | 20,467 | 94.6% |
| Point user | 512 | 18,598 | 21,046 | 88.4% |
| Orders | 64 | 10,178 | 9,818 | 103.7% |
| Orders | 512 | 9,475 | 11,241 | 84.3% |
| Summary | 64 | 12,863 | 12,205 | 105.4% |
| Summary | 512 | 12,421 | 12,447 | 99.8% |
| Insert | 64 | 10,409 | 11,228 | 92.7% |
| Insert | 512 | 10,214 | 11,365 | 89.9% |

The remaining clean-seed sample medians are shown as Slang / Go pairs. RSS is
the sampled process peak, converted from KiB to MiB. PostgreSQL time is the
mean server execution time per SQL call:

| Route | Clients | p99 ms | CPU µs/request | Peak RSS MiB | PostgreSQL ms/query |
|---|---:|---:|---:|---:|---:|
| Point user | 64 | 9.47 / 8.68 | 121.57 / 109.16 | 13.0 / 27.6 | 0.0190 / 0.0198 |
| Point user | 512 | 49.35 / 38.12 | 133.09 / 104.69 | 29.4 / 49.3 | 0.0199 / 0.0198 |
| Orders | 64 | 16.16 / 22.32 | 244.53 / 219.84 | 20.0 / 31.2 | 0.1222 / 0.1782 |
| Orders | 512 | 127.79 / 65.25 | 268.86 / 194.34 | 32.1 / 52.9 | 0.1432 / 0.1278 |
| Summary | 64 | 12.23 / 16.40 | 165.37 / 157.67 | 13.0 / 27.9 | 0.0728 / 0.1004 |
| Summary | 512 | 66.71 / 79.35 | 176.17 / 149.90 | 30.2 / 48.5 | 0.0761 / 0.1056 |
| Insert | 64 | 13.76 / 13.97 | 178.77 / 139.55 | 18.6 / 31.5 | 0.2245 / 0.2041 |
| Insert | 512 | 67.49 / 58.51 | 197.85 / 144.94 | 28.0 / 51.0 | 0.2605 / 0.2065 |

PostgreSQL reports one execution of one prepared SQL statement per successful
request. The Slang client combines Parse/Bind/Describe/Execute/Sync in one
extended-protocol exchange on a fresh statement and skips Parse/Describe on a
cached run, so the route gap is not an extra network round trip. Mean PostgreSQL
execution ranged from roughly 0.02 ms on point lookups to 0.29 ms on inserts
in the clean-seed runs, versus 5-55 ms end-to-end means under those loads.
The benchmark's current `__profile` endpoint did not expose pool-wait counters,
so pool wait is not yet separated from task scheduling and response work.

Perf samples on the orders route (64 clients, Slang and Go) found a similar
kernel share: `_raw_spin_unlock_irqrestore` was 22.2% for Slang and 22.5% for
Go, largely futex wakeups and TCP receive/transmit work. Slang's largest
user-space symbols were spread across GC allocation (2.1%), PostgreSQL row
handling (about 4% across `step`, `bin_int`, and `get_text`), array pushes
(2.3%), task-yield checks (2.9%), and JSON string encoding (1.2%). Go's
largest corresponding symbols were runtime object lookup/allocation (about
4.7%), pgx row scan (1.1%), and JSON encoding (1.2%). This profile does not
identify a single dominant function that explains the high-concurrency gap.

The acceptance target remains open. Current evidence points to driver decode,
allocation, task scheduling, and response construction as the next areas to
separate with route-specific pool-wait instrumentation and longer matched
ABBA runs. Do not present this patch as Go parity.

## New VPS results and profiling plan (2026-10-09)

The run `20261009T190756Z-benchmark-slang` is committed under
`bench/results/20261009T190756Z-benchmark-slang/`. It used 16 application
workers, 8 load-generator CPUs, 8 database CPUs, a 64-connection pool, and
the full 1M-user / 20M-order data set. The same-run ratios are severe and
repeatable across three rounds:

| Route | Clients | Slang / Go req/s | Slang / Go | Slang / Go p50 ms | App CPU cores | PostgreSQL CPU cores |
|---|---:|---:|---:|---:|---:|---:|
| Point | 64 | 5,127 / 153,254 | 3.3% | 11.94 / 0.40 | 3.53 / 11.60 | 0.52 / 7.68 |
| Point | 512 | 3,643 / 149,952 | 2.4% | 133.52 / 3.33 | 3.95 / 12.08 | 0.38 / 7.63 |
| Mix | 64 | 6,108 / 82,669 | 7.4% | 10.41 / 0.61 | 4.37 / 13.98 | 0.98 / 5.09 |
| Mix | 512 | 4,021 / 100,904 | 4.0% | 136.95 / 4.77 | 4.25 / 14.97 | 0.65 / 6.07 |

These measurements show that Slang feeds PostgreSQL far less work than Go and
has much higher end-to-end latency. They do **not** establish mutex contention:
the sampler records aggregate CPU time, not lock waits, pool wait, or SQL
execution time. The run's host check failed (Rust compute was 449 ms against a
1,577 ms baseline), so it must not be compared directly with the earlier
CCX33/local run. Its within-run language comparison remains useful. The
recorded `git_dirty` flag is true, and the run did not retain the corresponding
worktree diff, so the exact measured source tree cannot be reconstructed from
the run directory. The fixed 10k/s row also delivered only 4,306 Slang requests
per second; its zero error count does not mean it met the target rate.

The route source still shows one `pool_query`/`pgxpool` query call per database
request. In Slang, a normal prepared query sends one extended-protocol batch
and reads through one `ReadyForQuery`; the source does not point to extra
round trips as the cause. This is a source-level exchange count, not a packet
capture. The exact split between acquisition, client protocol and row
decoding, and PostgreSQL execution has not been measured on this VPS.

An opt-in `PG_PROFILE=1` mode now emits per-response pool-acquire and
client-query-plus-row-decode nanoseconds on the four database routes. The
`bench/latgen` `-pg-profile` option captures their distributions. With the
server warmed before sampling, acquire duration measures pool acquisition
latency in the steady state; the client duration includes the driver exchange
result decoding and connection release, but excludes JSON encoding. Run each
route separately at 64 and 512 HTTP connections for Slang and Go. For this
diagnostic run only, enable `pg_stat_statements`, snapshot/reset it after
warmup and before each sample, and compare its per-query `mean_exec_time` and
`calls` deltas with the client measurements. Use its call deltas to compare SQL
executions with HTTP response counts; expect one execution per successful
database request. The logical
protocol exchange count is one per query by both clients' source paths after
warmup; count SQL executions separately from TCP send/receive syscalls.

For the diagnostic database only, enable `pg_stat_statements` in
`shared_preload_libraries`, restart PostgreSQL, and run
`CREATE EXTENSION IF NOT EXISTS pg_stat_statements` in the benchmark database.
After warming the API and before each route sample, reset the extension as a
PostgreSQL superuser. Save CSV snapshots from
`bench/suite/api/pg_profile_stats.sql` immediately before and after the sample;
subtract `calls`, `rows`, and `total_exec_time` by `queryid`. Keep this
extension out of ordinary benchmark runs so its shared statistics overhead
does not alter the published baseline.

Launch each API with `PG_PROFILE=1`, warm the chosen route, reset and snapshot
the database statistics, then run for 20 seconds with
`go run bench/latgen/main.go -addr 127.0.0.1:PORT -path ROUTE -c CLIENTS -d 20s -pg-profile`.
Use the same path, client count, seeded database state, and timing for both
languages; sample Slang/Go/Go/Slang (then reverse order for the next route) at
64 and 512 clients. Profile the four routes separately, reset the seeded
database before the insert comparison, and retain the tool output plus both
SQL snapshots.

Do not select a driver or scheduler optimization until these phase timings and
a matched `perf` profile identify the cost. The 98%-of-Go acceptance target
still applies per route and concurrency level.
