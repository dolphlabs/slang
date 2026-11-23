# Benchmarks

> Every cross-language run, including the ones slang loses.

slang is measured against C, Go, Rust, C#, Java, Python, Bun and
Node.js by [`bench/suite`](https://github.com/dolphlabs/slang/tree/dev/bench/suite):
the same SQL, the same response contracts, the same dataset, and a
conformance gate that runs before anything is timed, so a language that
fails to build or fails conformance is reported as failed, not
measured -- a number here means the implementation actually did the
work. Two tiers: **light** (raw HTTP connection handling, CPU +
allocation throughput) and **heavy** (a Postgres-backed JSON API and a
big-data batch job), full contract in
[`bench/SPEC.md`](https://github.com/dolphlabs/slang/blob/dev/bench/SPEC.md).

The full record below is reproduced verbatim from `bench/RESULTS.md`,
including the runs where slang loses and the runs that are only
partial. **RPS alone is not a win**: a result worth trusting needs
throughput considered alongside tail latency and memory together, on a
dedicated host at the scale the SPEC calls for -- not whichever single
number happens to flatter one runtime.

# Cross-language suite — results

Two runs are recorded here, newest first. They ran on different hosts, so
compare languages **within** a run, never one run's numbers against the
other's.

# Run 2026-11-23: full suite, both tiers

The first run of the whole suite defined in
[`bench/SPEC.md`](https://github.com/dolphlabs/slang/blob/dev/bench/SPEC.md):
the light tier (`http-static`, `compute`) and the heavy tier (a
Postgres-backed JSON API, `api`, and a CSV aggregate, `batch`). Every
language passed the conformance gate (`bench/suite/lib/conformance.py`)
and the batch output check before anything was timed; no server died.

**Languages: slang, Go, Rust, Java, Bun, Node.js.** C# built but failed
`api` conformance and its `http-static` server did not start on this host,
so it was left out of the run rather than measured broken. C and Python
were not run.

**Read the host first.** A shared-vCPU cloud VM with 4 vCPUs, which are
2 physical cores with 2 hyperthreads each. The suite's default split gives
the server under test CPUs 0-1 (**one physical core**), the load generator
CPU 2 and Postgres CPU 3, so those two share the other core. That is a
quarter of the host `bench/CURSOR.md` asks for, and the run's own host
check says so: Rust `compute` took 3,220 ms against the reference host's
1,577 ms, so `summary.md` marks the run **not comparable with other
hosts**. CPU steal over the run was 0.0%.

## Machine

| field | value |
|---|---|
| date (UTC) | 2026-11-23 15:43–16:53 |
| host | Hetzner Cloud, Helsinki, shared vCPU |
| OS / kernel | Ubuntu 26.04.1 LTS, `7.0.0-43-generic` |
| CPU | AMD EPYC-Milan, 4 vCPU = 2 cores × 2 threads, KVM |
| RAM | 15 GiB |
| CPU split | server `0-1` (`WORKERS=2`), load generator `2`, Postgres `3` |
| rounds | 3, medians shown |
| durations | `HTTP_DUR=15s`, `API_DUR=20s`, `WARMUP=10s` |
| dataset | 1M users / 20M orders; batch **50M rows** / 2.5M users |
| postgres | 18.6 (26.04 ships no 16) |
| go | go1.24.1 |
| rustc | 1.95.0 |
| java | OpenJDK 21.0.13.1 |
| bun / node | 1.2.5 / v22.14.0 |
| wrk / wrk2 | 4.1.0 / 4.0.0 (`giltene/wrk2@44a94c1`) |
| commit measured | `c78f020c36dceeff8aa1c47e81622660821b01cc` |

Batch ran at half the specified 100M rows: 16 GB cannot hold Postgres's
4 GB of shared buffers and Java's `-Xmx12g` at once, and `bench/CURSOR.md`
names 50M as the fallback. Run id `20261123-hel1-4vcpu`; `env.json`,
`results.json`, `summary.md`, `run.log` and every raw wrk log are in
[`bench/results/20261123-hel1-4vcpu/`](https://github.com/dolphlabs/slang/tree/dev/bench/results/20261123-hel1-4vcpu).

## What this run shows

- **JSON with no database (`api/quote`) is the cleanest signal**, with
  round-to-round spread of 3-8%: slang 5,592 req/s at 64 connections,
  Rust 5,183, Go 4,035, Bun 3,914, Java 3,601, Node 2,850. slang and Rust
  are level within noise; both are 24-38% ahead of Go.
- **Postgres-backed reads (`api/point`, `api/mix`) are database-bound.**
  Postgres sat at 0.94-0.97 of its one core in every run but Node's, and
  rounds spread 17-39%, round 1 usually lowest. slang has the highest
  median in all four, but slang, Java, Go and Rust are within that spread
  of each other: read them as one tier, with Bun behind and Node clearly
  last.
- **At a fixed rate (wrk2), every language but Node holds the target** of
  2,000 and 10,000 req/s; at 10,000/s slang's p99 is 3.61 ms, Rust's 3.73,
  Go's 7.98. Node falls behind at 10,000/s (6,399 served, multi-second
  latency).
- **Batch: slang is 13% slower than Go and uses a fifth of the memory**
  (9.6 s and 433 MB against Go's 8.5 s and 2.1 GB). Rust is fastest at
  5.0 s. Spread 1-3% (Rust 10%).
- **Memory is consistent everywhere**: slang's peak RSS is the lowest or
  second lowest in every workload, beside Rust and Go; Java sits at
  700 MB+ in the API.
- **`http-static` measured the load generator, not the servers.** One CPU
  of wrk tops out near 19,000 req/s; every server but Node lands within
  that band while using 1.1-1.5 of its 2 CPUs. Only the memory column
  separates them there.

## `api`

Median of 3 rounds, sorted by req/s. `CPU cores` is the server's,
`DB CPU` Postgres's (one core available).

### `quote` — JSON in and out, no database

| lang | conns | req/s | p50 ms | p99 ms | peak RSS MB | CPU cores |
|---|---:|---:|---:|---:|---:|---:|
| slang | 64 | 5,592 | 11.21 | 27.79 | 38.2 | 1.89 |
| rust | 64 | 5,183 | 12.77 | 19.99 | 48.0 | 1.98 |
| go | 64 | 4,035 | 15.57 | 38.08 | 90.7 | 1.97 |
| bun | 64 | 3,914 | 18.05 | 27.18 | 312.7 | 1.98 |
| java | 64 | 3,601 | 17.00 | 34.76 | 713.2 | 1.97 |
| node | 64 | 2,850 | 21.62 | 43.88 | 366.2 | 1.98 |
| slang | 512 | 5,273 | 97.75 | 206.62 | 89.0 | 1.88 |
| rust | 512 | 5,135 | 93.50 | 146.89 | 117.1 | 1.98 |
| go | 512 | 4,519 | 116.68 | 232.23 | 245.6 | 1.97 |
| bun | 512 | 4,089 | 124.73 | 133.05 | 329.9 | 1.98 |
| java | 512 | 3,631 | 139.68 | 158.91 | 750.8 | 1.97 |
| node | 512 | 2,769 | 141.05 | 6,270.00 | 366.8 | 1.98 |

Node had 0.20% errors at 512 connections; every other row had none.

### `point` — one indexed row per request

| lang | conns | req/s | p50 ms | p99 ms | peak RSS MB | CPU cores | DB CPU |
|---|---:|---:|---:|---:|---:|---:|---:|
| slang | 64 | 38,043 | 1.66 | 3.21 | 83.2 | 1.68 | 0.96 |
| java | 64 | 33,288 | 1.88 | 3.82 | 724.7 | 1.00 | 0.96 |
| go | 64 | 31,896 | 1.96 | 3.89 | 191.0 | 1.31 | 0.96 |
| rust | 64 | 31,564 | 1.84 | 4.49 | 61.0 | 0.96 | 0.97 |
| bun | 64 | 28,383 | 2.18 | 4.95 | 272.9 | 1.39 | 0.96 |
| node | 64 | 16,117 | 3.53 | 9.92 | 354.4 | 1.98 | 0.42 |
| slang | 512 | 38,065 | 13.39 | 15.93 | 37.4 | 1.85 | 0.97 |
| java | 512 | 35,367 | 14.28 | 17.62 | 719.6 | 1.37 | 0.97 |
| go | 512 | 31,672 | 15.95 | 21.86 | 85.8 | 1.26 | 0.97 |
| rust | 512 | 28,769 | 15.20 | 33.21 | 33.0 | 1.09 | 0.97 |
| bun | 512 | 28,154 | 17.66 | 39.47 | 290.5 | 1.55 | 0.97 |
| node | 512 | 14,818 | 33.58 | 314.38 | 356.1 | 1.98 | 0.29 |

### `mix` — 50% user by id, 15% order lists, 10% summaries, 10% new orders, 15% quotes

| lang | conns | req/s | p50 ms | p99 ms | peak RSS MB | CPU cores | DB CPU |
|---|---:|---:|---:|---:|---:|---:|---:|
| slang | 64 | 18,093 | 3.05 | 12.48 | 34.1 | 1.67 | 0.97 |
| go | 64 | 16,179 | 3.76 | 11.59 | 62.4 | 1.60 | 0.94 |
| rust | 64 | 13,565 | 4.10 | 43.13 | 40.8 | 1.13 | 0.97 |
| java | 64 | 12,269 | 4.62 | 26.28 | 751.7 | 1.22 | 0.97 |
| bun | 64 | 11,857 | 4.98 | 16.27 | 286.2 | 1.79 | 0.96 |
| node | 64 | 10,225 | 6.02 | 16.70 | 328.3 | 1.97 | 0.66 |
| slang | 512 | 19,730 | 29.06 | 39.97 | 87.7 | 1.89 | 0.97 |
| go | 512 | 17,716 | 31.89 | 44.70 | 189.9 | 1.71 | 0.94 |
| rust | 512 | 14,606 | 38.90 | 55.70 | 77.1 | 1.33 | 0.97 |
| java | 512 | 13,141 | 43.50 | 69.71 | 728.9 | 1.45 | 0.95 |
| bun | 512 | 12,575 | 44.41 | 71.87 | 301.0 | 1.94 | 0.93 |
| node | 512 | 9,433 | 53.31 | 1,170.00 | 354.6 | 1.98 | 0.49 |

### `mix` at a fixed rate (wrk2, 256 connections)

| lang | target | served | p50 ms | p99 ms | p99.9 ms | peak RSS MB |
|---|---:|---:|---:|---:|---:|---:|
| slang | 10,000 | 9,686 | 1.41 | 3.61 | 5.54 | 61.8 |
| rust | 10,000 | 9,686 | 1.55 | 3.73 | 4.68 | 52.3 |
| java | 10,000 | 9,686 | 1.57 | 4.50 | 6.24 | 692.6 |
| bun | 10,000 | 9,686 | 1.65 | 5.20 | 7.39 | 244.0 |
| go | 10,000 | 9,686 | 1.59 | 7.98 | 11.95 | 127.1 |
| node | 10,000 | 6,399 | 4,920 | 6,710 | 6,950 | 361.0 |
| slang | 2,000 | 1,942 | 0.94 | 2.24 | 3.72 | 82.6 |
| go | 2,000 | 1,942 | 0.97 | 2.12 | 3.37 | 232.7 |
| java | 2,000 | 1,942 | 0.96 | 2.18 | 3.52 | 712.6 |
| bun | 2,000 | 1,942 | 0.99 | 2.34 | 3.82 | 291.6 |
| rust | 2,000 | 1,942 | 1.02 | 2.16 | 3.18 | 92.6 |
| node | 2,000 | 1,942 | 1.24 | 5.96 | 10.02 | 366.8 |

`served` is requests over the whole 20 s, wrk2's start-up calibration
included, which is why a target of 10,000 reads 9,686.

## `batch` — 50M-row CSV aggregate

| lang | wall s | peak RSS MB | CPU s | output agrees |
|---|---:|---:|---:|---|
| rust | 5.01 | 2,110.6 | 9.7 | yes |
| java | 6.98 | 2,453.1 | 13.6 | yes |
| go | 8.52 | 2,098.7 | 16.4 | yes |
| slang | 9.60 | 433.0 | 18.7 | yes |
| node | 22.20 | 1,177.7 | 42.2 | yes |
| bun | 25.23 | 2,379.1 | 48.2 | yes |

## `compute`

| lang | wall ms | tasks/s | peak RSS MB | CPU s |
|---|---:|---:|---:|---:|
| node | 3,237 | 308 | 81.7 | 6.5 |
| rust | 3,247 | 307 | 13.2 | 6.1 |
| bun | 3,408 | 293 | 93.7 | 6.5 |
| java | 3,428 | 291 | 104.7 | 6.8 |
| slang | 3,709 | 269 | 8.7 | 7.3 |
| go | 3,921 | 255 | 8.2 | 7.7 |

## `http-static` (load-generator bound)

| lang | conns | req/s | p50 ms | p99 ms | peak RSS MB | CPU cores |
|---|---:|---:|---:|---:|---:|---:|
| rust | 50 | 19,405 | 0.51 | 1.88 | 3.6 | 1.14 |
| bun | 50 | 19,351 | 0.52 | 2.00 | 142.2 | 0.75 |
| slang | 50 | 19,220 | 0.48 | 1.82 | 3.0 | 1.51 |
| go | 50 | 18,844 | 0.53 | 1.96 | 9.8 | 1.09 |
| java | 50 | 18,508 | 0.57 | 2.08 | 114.4 | 1.17 |
| node | 50 | 14,881 | 3.15 | 8.80 | 178.4 | 1.74 |
| bun | 200 | 19,962 | 2.21 | 8.16 | 184.3 | 0.92 |
| rust | 200 | 19,418 | 1.97 | 7.15 | 4.0 | 1.15 |
| slang | 200 | 19,132 | 1.85 | 6.92 | 4.6 | 1.50 |
| go | 200 | 18,553 | 2.10 | 7.78 | 9.8 | 1.09 |
| java | 200 | 17,911 | 2.17 | 7.71 | 116.8 | 1.12 |
| node | 200 | 15,062 | 13.03 | 17.28 | 187.2 | 1.73 |

## Changes made to run on this host

- `setup_host.sh` installs the OS's Postgres where 16 is not packaged
  (18 on Ubuntu 26.04), and builds wrk2 with its Lua bytecode emitted as
  C: the bundled LuaJIT's ELF object is read as corrupt by 26.04's
  binutils, which left every fixed-rate run panicking on start.
- `bench/compute/cs/Compute.csproj` targets `net10.0`, like the suite's
  other C# projects (the build failed with NETSDK1005). C# still failed
  conformance and was left out.
- The slang programs read their settings with `to_int` instead of an
  `extern fn atoi`, and the API scans an id with `for c in s` instead of
  copying it to bytes. No implementation's logic, libraries or flags
  changed; slang's gains since the last run come from the compiler and
  runtime it was built with.

# Earlier run 2026-09-17: light tier only (interim)

**This is a partial run, published early.** It covers only the **light
tier** (`http-static`, `compute`) of the suite defined in
[`bench/SPEC.md`](https://github.com/dolphlabs/slang/blob/dev/bench/SPEC.md):
raw connection handling and CPU + allocation throughput, with no
database and no JSON in the loop. The **heavy tier** (a Postgres-backed
JSON API and a big-data batch job — the workloads that exercise a
driver, a connection pool, and a JSON codec under load) was aborted
partway through a `ROUNDS=3` run to stop runaway compute spend, and is
not included here. The 2026-11-23 run above is the first full run, heavy
tier included.

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

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
