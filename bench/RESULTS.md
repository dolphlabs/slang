# Cross-language suite — interim results (light tier only)

**This is a partial run, published early.** It covers only the **light
tier** (`http-static`, `compute`) of the suite defined in
[`bench/SPEC.md`](https://github.com/dolphlabs/slang/blob/dev/bench/SPEC.md):
raw connection handling and CPU + allocation throughput, with no
database and no JSON in the loop. The **heavy tier** (a Postgres-backed
JSON API and a big-data batch job — the workloads that exercise a
driver, a connection pool, and a JSON codec under load) was aborted
partway through a `ROUNDS=3` run to stop runaway compute spend, and is
not included here. A full run, heavy tier included, is queued; this
page will be replaced when it lands.

**The host was undersized for a publish-grade run.** 4 vCPUs / 15 GiB
RAM on Docker overlay storage, run via a Cursor background agent —
well below the 16+ cores / 64 GiB+ / local NVMe, dedicated-host bar
[`bench/CURSOR.md`](https://github.com/dolphlabs/slang/blob/dev/bench/CURSOR.md)
sets for a result meant to be trusted. Absolute numbers here (a 4-core
box serving both the app *and* the load generator *and* Postgres on
the same four cores) are lower and noisier than a dedicated box would
give; treat rankings as a rough first read, not a final word.

**Shown here: C#, Java, Go, Rust, Bun, Node.js, and slang.** The suite
also measures C and Python on every run (see the run's own
`results.json` for those), but this page's comparison set is
restricted to the seven above.

The suite gates every language behind a conformance check before
measuring it (`bench/suite/lib/conformance.py`) — a language that
fails to build or fails conformance is reported as failed, not
measured, so a number here means the implementation actually did the
work, not just that it ran. All nine languages passed the light-tier
gate on this run.

## Machine

| field | value |
|---|---|
| date (UTC) | 2026-09-17 20:34 |
| OS / kernel | Ubuntu 24.04.4 LTS, `6.12.94+` |
| CPU | Intel Xeon (cloud vCPU), 4 cores, 1 thread/core, 1 socket |
| RAM | 15 GiB, no swap |
| virtualization | Docker (overlay storage) |
| CPU split | server `0-1` (2 cores), load generator `2`, db `3` (unused by the light tier) |
| rounds | 3 |
| go | go1.24.1 linux/amd64 |
| rustc | 1.95.0 |
| dotnet | 10.0.401 |
| java / javac | OpenJDK 21.0.12 |
| bun | 1.2.5 |
| node | v22.14.0 |
| wrk | debian/4.1.0-4build2 \[epoll\] |
| commit measured | `0fad8dcc9bf191519fe3a15b1eb6e56ef8715aab` |

Run id `20260917T203432Z-cursor-scaled20`. Full `env.json` /
`results.json` / raw logs are in the PR this run shipped in.

## `compute`

CPU-bound: prime counting plus small allocations across many
concurrent tasks (`bench/suite/light/compute/*`, `CC_TASKS=1000
CC_WORK=20000 CC_ALLOC=200`), every language checked against Go's
`total_primes`/`total_alloc_sum` for correctness before timing counts.
Median of 3 rounds, sorted fastest first.

| lang | wall ms | tasks/s | peak RSS MB | CPU s |
|---|---:|---:|---:|---:|
| rust | 1,498 | 667 | 10.1 | 2.73 |
| slang | 1,757 | 569 | 13.3 | 3.21 |
| bun | 1,785 | 560 | 88.4 | 3.21 |
| node | 1,801 | 555 | 81.1 | 3.58 |
| java | 1,990 | 502 | 72.5 | 3.69 |
| csharp | 2,072 | 482 | 41.7 | 3.60 |
| go | 2,637 | 379 | 8.3 | 5.22 |

## `http-static`

`GET /`, a fixed 200-byte body, `wrk -c{50,200} -d30s --latency`.
Median of 3 rounds, sorted by req/s (fastest first).

None of these implementations parse an HTTP request -- every language's
`http-static` entry is a raw-socket responder (slang's is
`bench/http/main.sl`/`go_raw`'s shape; see
[`bench/http/README.md`](https://github.com/dolphlabs/slang/blob/dev/bench/http/README.md)'s
axis table). This tier answers "how fast is the socket layer," not
"what does a real HTTP server cost" -- `bench/run_http_realserver.sh`
is the harness for that question, and it is not this one.

### 50 connections

| lang | req/s | p50 ms | p99 ms | peak RSS MB | CPU cores |
|---|---:|---:|---:|---:|---:|
| slang | 39,857 | 0.33 | 1.01 | 2.9 | 1.03 |
| java | 38,942 | 0.36 | 1.14 | 125.6 | 1.30 |
| go | 38,439 | 0.30 | 1.06 | 9.6 | 1.12 |
| bun | 38,043 | 0.27 | 1.19 | 146.0 | 0.73 |
| rust | 38,021 | 0.26 | 0.97 | 3.2 | 1.22 |
| csharp | 33,030 | 0.31 | 1.16 | 40.0 | 1.86 |
| node | 29,190 | 1.60 | 4.26 | 184.6 | 1.64 |

### 200 connections

| lang | req/s | p50 ms | p99 ms | peak RSS MB | CPU cores |
|---|---:|---:|---:|---:|---:|
| bun | 38,117 | 1.30 | 4.65 | 238.3 | 0.88 |
| rust | 37,595 | 1.00 | 3.68 | 3.6 | 1.16 |
| java | 37,017 | 1.16 | 4.13 | 124.3 | 1.29 |
| go | 36,492 | 1.13 | 4.13 | 9.8 | 1.09 |
| slang | 35,553 | 1.31 | 4.44 | 4.2 | 1.04 |
| csharp | 35,305 | 1.20 | 4.35 | 40.8 | 1.78 |
| node | 29,541 | 6.66 | 9.28 | 205.5 | 1.60 |

## Reading these numbers

All seven are within a fairly narrow band on raw throughput at this
scale — a few thousand req/s apart on a 4-core box is not a strong
signal either way, and Node's lower numbers here are a known shape for
its single-process baseline HTTP server under this harness, not a
general Node.js finding. **Memory is the more legible gap**: slang,
Rust, Go and C sit in single-digit-to-low-double-digit MB; Bun, Node,
and Java's JIT-warmed footprint run into the hundreds. None of this
substitutes for the heavy tier, which is where a driver, a connection
pool, and JSON encode/decode under sustained load will separate these
runtimes more than an empty HTTP response does.

## Known gaps in this run

- **Heavy tier not run.** No `api` (Postgres-backed JSON service) or
  `batch` (big-data CSV aggregate) numbers exist yet for any language.
- **Java's `api` implementation failed conformance** on this host (no
  `bench.Main` sources were present for the Maven build to compile) —
  irrelevant to the light-tier numbers above, which don't touch it,
  but it means Java's heavy-tier numbers aren't just missing, they're
  currently broken and need a fix before the next run.
- Host is a 4-core cloud VM sharing its cores between the server under
  test, the load generator, and Postgres — see `bench/CURSOR.md` for
  why that matters and what a publish-grade host looks like.
