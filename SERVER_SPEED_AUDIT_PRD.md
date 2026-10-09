# PRD: Server speed audit, areas 1-5

Status: five-part audit complete; no source change passed the performance
gate (2026-10-09).

## Problem

The API benchmark shows a mixed-workload throughput and latency gap against Go
on the current `dev` build. A previous quote/decode profile points to JSON
parsing, allocation and collector coordination, while the mixed endpoint also
spends time in PostgreSQL and socket scheduling. A useful optimization needs
to identify which cost limits each workload and demonstrate a repeatable
improvement without trading away tail latency or memory.

## Product and technical context

slang compiles to C and runs M:N green threads on a worker pool with a precise,
generational stop-the-world collector. The heavy API benchmark runs four server
workers on CPUs 0-3, a load generator on CPUs 4-5, and PostgreSQL on CPUs 6-7.
Its quote endpoint parses a roughly 110 KB, 2,000-item JSON body; the mixed
scenario combines quote, point reads, pagination, summaries and inserts.

Relevant code paths are `bench/suite/api/slang/main.sl` (routes and request
body buffer), `runtime/sl_json.c` (typed JSON parser), `stdlib/pg/pg.sl`
(connection pool and PostgreSQL protocol), `stdlib/http/http.sl` (request
framing and connection buffers), and the collector/scheduler in `runtime/`.
The benchmark contract and guard live under `bench/suite/`, `bench/latgen/`,
and the prepared local `slrepro` containers.

## Goal

Identify and, only where measurements support it, reduce the backend costs
behind the quote and mixed API workloads. Report throughput, p50/p99/p99.9,
server CPU per request, peak RSS, errors, and PostgreSQL CPU. Compare slang
with Go on the same host and use ABBA ordering for any before/after claim.

## Scope

1. Establish current `dev` versus Go baselines for quote and mixed workloads
   at 64 and 512 connections.
2. Profile the current mixed server and attribute CPU to JSON, allocation/GC,
   scheduling, PostgreSQL and network paths.
3. Test the smallest profile-supported server or decoder optimization; retain
   it only if instruction counts or repeated timings show a material gain.
4. Measure PostgreSQL CPU and isolate read/query overhead with route-level
   load tests before changing the driver, pool or SQL path.
5. Measure per-connection and peak memory at high concurrency, then test any
   buffer change against throughput, tail latency and RSS.

## Non-goals and constraints

- No change to JSON syntax, public APIs, SQL semantics, or HTTP behavior.
- No decoder safepoints or visibility of partially built decode results.
- No edits to `bench/http/main.sl`.
- No benchmark measurement without `bench/guard.sh` ownership verification.
- No speed claim from a single timing or from RPS without p99 and RSS.
- Do not change production code until the candidate is supported by a profile
  and a measurable test; keep all existing JSON, memory, TLS, and preemption
  invariants.

## Baseline evidence

On the local Linux `slrepro` containers, source at `1a0d630`, an ABBA x4 set
with 10 s warmup and 15 s samples gave these medians (raw samples are retained
in the benchmark containers):

| Workload | Connections | slang req/s | Go req/s | slang p99 ms | Go p99 ms | slang RSS MB | Go RSS MB |
|---|---:|---:|---:|---:|---:|---:|---:|
| quote | 64 | 4,821 | 4,070 | 41.3 | 52.4 | 36.9 | 56.0 |
| quote | 512 | 4,537 | 4,738 | 202.5 | 337.0 | 116.7 | 245.7 |
| mix | 64 | 9,611 | 11,381 | 26.5 | 20.6 | 43.7 | 62.3 |
| mix | 512 | 9,446 | 11,635 | 142.5 | 176.5 | 103.1 | 193.0 |

Raw run ranges overlap materially, especially for tail latency; these medians
are directional and do not alone justify a performance claim. Every custom
mixed run had zero timeouts, socket errors and non-2xx responses.

The four ABBA samples per implementation are below, in the order
`req/s / p99 ms / server CPU us per request / peak RSS MB`:

| Workload | slang samples | Go samples |
|---|---|---|
| quote c64 | `4821/46.361/682.9/37.4`, `4799/34.469/680.0/35.2`, `4950/36.162/664.4/36.3`, `4509/48.049/737.8/41.1` | `4788/44.017/771.9/54.3`, `3775/55.023/989.1/53.2`, `4364/49.741/856.1/53.9`, `3675/69.755/1015.0/61.6` |
| quote c512 | `4170/322.985/785.2/115.8`, `4748/180.817/691.0/110.0`, `4451/214.959/734.8/117.5`, `4622/193.501/709.4/118.6` | `3523/667.312/1114.8/249.9`, `4891/380.514/794.5/241.5`, `4735/293.402/833.1/284.6`, `4739/238.020/832.4/226.4` |
| mix c64 | `12256/15.352/253.6/42.4`, `9245/30.625/327.3/43.0`, `7957/46.331/373.3/44.1`, `9976/22.371/311.7/43.4` | `13167/18.261/279.5/62.4`, `11069/20.836/336.1/62.2`, `10207/26.090/349.3/63.9`, `11692/20.304/309.4/61.9` |
| mix c512 | `10894/96.566/303.2/104.0`, `6491/306.234/484.0/102.1`, `8697/188.463/371.6/101.8`, `11037/77.288/298.7/106.5` | `12549/92.454/299.1/194.1`, `9565/279.440/373.5/194.5`, `12590/79.880/296.4/191.8`, `10720/260.613/339.7/191.4` |

One mixed c512 profile sampled task-clock at 199 Hz for about 15 seconds with
zero lost samples. Leading self costs were kernel spin unlock (12.7%),
`sl_slang_quote` (9.7%), GC page allocation (6.1%), JSON whitespace skipping
(3.7%), signed integer decode (3.4%), GC allocation (3.4%), array push (3.1%),
and raw string parsing (2.8%). The call graph also included the PostgreSQL
pool/query path and networking. Hardware counters are unavailable in this
container.

In a separate 25-second slang mix c512 sample, Postgres consumed about 1.65
CPU cores of its two-core allocation, at 9,528 requests/s. A comparable Go
sample reached 13,737 requests/s and consumed about 1.84 cores. Those cgroup
counters include warmup and startup overhead and are only a lead, not a
per-query attribution. They motivate the route-level comparison in area 4.

The existing JSON-specific PRD/profile on `perf/json-decode-speed` tested a
word-at-a-time unescaped-string scan: callgrind instructions were effectively
unchanged and native timings overlapped noise. Do not repeat that candidate or
claim a decoder win from the profile alone.

## Results of areas 1-5

**1. Cross-language baseline.** The quote/mix ABBA table above is the current
baseline. Its large raw spread means later comparisons need repeated runs and
an idle host.

**2. Server profile.** The profile supports JSON and allocation work for quote,
and a meaningful PostgreSQL/network path for mix. GC page allocation and
kernel scheduling are visible, but no single additional runtime edit is
supported by this one sample.

**3. Decoder experiment rejected.** A whitespace fast path was measured in
the decode probe and quote server. Across six c64 quote samples per build,
median current/candidate values were 5,104/5,192 req/s, p99 34.6/27.9 ms,
CPU/request 653/636 us, and RSS 36.0/35.6 MB. At c512, medians were
4,587/4,539 req/s, p99 191.8/208.6 ms, CPU/request 720/721 us, and RSS
118.0/117.0 MB. The c64 tail result did not transfer to c512. In an ABBA
single-task native probe (2,000 decodes), medians were 631.5 ms for current
and 639 ms for the candidate. Callgrind's 200-decode median was 546.1M
instructions for current and 538.1M for the candidate, but the raw ranges
overlapped and the native timing went the other way. The code was discarded;
there is no measured decoder win.

Raw quote experiments use `req/s / p99 ms / CPU us per request / RSS MB`;
current dev and the experimental fast path, in chronological ABBA order:

| Connections | Current dev | Candidate |
|---:|---|---|
| 64 | `5103/33.581/651.5/36.0`, `5106/33.680/653.7/36.0`, `4703/35.419/707.2/38.7`, `4907/38.606/674.0/35.1`, `5384/39.586/611.9/35.9`, `5391/29.718/609.7/34.8` | `5088/31.660/650.0/37.3`, `5235/29.897/632.8/35.4`, `5148/27.427/639.8/35.6`, `5091/28.126/648.8/35.0`, `5960/27.588/553.4/35.5`, `5903/26.948/559.3/36.5` |
| 512 | `4997/187.363/656.9/115.2`, `4645/199.495/709.0/112.5`, `4528/175.163/731.9/121.8`, `4391/196.172/750.9/120.7` | `4964/185.906/660.5/122.2`, `4205/253.024/786.6/116.6`, `4446/231.265/737.6/116.2`, `4632/165.131/704.9/117.4` |

The direct 2,000-decode wall times were current `632, 631, 631, 633 ms` and
candidate `636, 638, 640, 652 ms`. The six callgrind instruction counts were
current `552.10, 543.79, 552.02, 545.16, 546.95, 543.89 M` and candidate
`545.62, 538.74, 537.02, 545.61, 537.42, 537.48 M`.

**4. PostgreSQL path.** A guarded point-read c512 ABBA set measured medians of
17,800 req/s and 58.5 ms p99 for slang, versus 20,736 req/s and 39.6 ms p99
for Go; raw throughput ranges were 16,055-19,178 and 19,176-21,711 req/s.
In separate 15-second point samples after a 5-second warmup, Postgres cgroup
CPU rose by about 38.2 CPU seconds over 20 seconds for slang (1.91 cores)
and 40.1 seconds for Go (2.01 cores). The latter is an approximate interval
because the counters include warmup and process setup. Both results point to
database query/protocol efficiency as a strong next profiling target; they do
not distinguish SQL execution from client round trips.

The raw point-read samples use `req/s / p99 ms / server CPU us per request /
RSS MB`: slang `19178/49.192/128.4/26.2`, `17064/67.727/145.7/38.7`,
`16055/73.349/156.9/39.0`, `18535/39.358/136.1/39.2`; Go
`21590/39.139/104.0/48.1`, `21711/36.975/102.7/48.2`,
`19176/39.968/118.2/50.3`, `19882/40.520/114.6/48.3`. All had zero
timeouts, socket errors and non-2xx responses.

**5. High-concurrency memory.** Existing c512 mixed runs measured about
103 MB RSS for slang and 193 MB for Go; quote c512 medians were about 117 MB
and 246 MB. `serve` reserves a 300,000-byte request arena (including a
262,144-byte read wire) and a 65,536-byte response arena per connection; the
compiler drops both arenas when the connection task returns. Slang's measured
RSS is lower, so changing these capacities has no demonstrated speed or
memory need. The reserved capacity is about 178 MiB across 512 connections,
but RSS is substantially lower because unused arena pages are not touched.

All measurements ran in the prepared local Linux Docker environment, not a
Codex Cloud host. Mixed runs had zero timeouts, socket errors or non-2xx
responses. The server guard checked socket ownership for every server sample.

Verification on this docs-only branch: `make test` completed successfully,
including the 16 KB GC stress, minor verifier, allocation/promotion budgets,
frame guards and `PASS generated C is warning-free`. The streamed test output
was not retained as one file, so this run's total case count was not captured.
`make docs` was not needed because no README, package API or site source
changed.

## Acceptance criteria

- Keep raw ABBA logs, server/DB CPU, RSS, host/toolchain details and error
  counts for every comparison.
- A source change must beat the measured spread on its targeted workload and
  cause no material regression in p99, p99.9, RSS or other workloads. The
  tested whitespace fast path failed this gate and was removed.
- A server performance claim includes p99 and peak RSS against Go.
- Any runtime, collector or codegen safety change passes the applicable GC
  verifier, warning sweep and complete `make test`; no overlapping test runs.
- Record outcomes and unresolved causes in `todo.md`, `next-steps.md`, and
  `fix-gc.md` as appropriate. Open a PR against `dev` only after the evidence
  and checks are complete.
