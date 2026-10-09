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
- The current container only has Go 1.22.2 while the benchmark declares Go
  1.23. Comparisons using 1.22 must be labeled and should be rerun with 1.23
  before making a final Go-parity claim.
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
