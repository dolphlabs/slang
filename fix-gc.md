# fix-gc: beat Go on the API workloads, stay in Rust's memory league

The plan that follows the CCX33 cross-language run (PR #287, commit
`f42f2b5`, 2026-10-01). One PR per numbered item, branched from `dev`,
never stacked. Tick items as they land and record the before/after numbers
next to them, as `next-steps.md` does.

**Order (2026-10-06, owner's decision):** the queue is the plan at the top
of `todo.md`, written from the #325 re-run. It cites the items here that are
still open as *(fix-gc N.N)*; this file keeps their detail and evidence.

Agreed with the owner on 2026-10-04. Decisions taken that day are in
[Decisions](#decisions); items that override standing rules in `AGENTS.md`
are marked **(overrides AGENTS.md)**.

## Goal

Two pass conditions, both checked on a CCX33 re-run with the same
configuration as #287 (4 server cores, 2 load-generator, 2 Postgres):

1. **Beat Go** on every `api` row, at 64 and 512 connections and at both
   fixed rates, on throughput **and** p99 (p99.9 at the fixed rates), and
   on `batch` wall time. `compute` already wins (1,837 ms vs 1,896, all
   three rounds) and must keep winning. `http/static` is capped by the
   load generator for every language, so there the measure is server CPU
   per request (slang 72-74 µs, Go 62).
2. **Memory in Rust's league:** on every row, slang's peak RSS is at most
   1.10x Rust's, aiming for at or below Rust. Rust is below Go everywhere,
   so this also keeps slang below Go.

Go's numbers to beat (#287 medians):

| row | Go req/s | Go p99 ms |
|---|---:|---:|
| quote c64 / c512 | 6,967 / 7,896 | 35.05 / 151.26 |
| mix c64 / c512 | 26,198 / 29,394 | 7.07 / 26.92 |
| point c64 / c512 | 34,005 / 34,980 | 2.70 / 16.31 |
| mix fixed 2000/s | — | 12.68 (p99.9 18.50) |
| mix fixed 10000/s | — | 13.72 (p99.9 17.58) |
| batch | 11.90 s wall | — |

Rows where slang's memory is outside Rust's league today:

| row | slang MB | Rust MB | ratio |
|---|---:|---:|---:|
| mix fixed 2000/s | 118.9 | 84.3 | 1.41 |
| mix fixed 10000/s | 83.9 | 65.3 | 1.28 |
| http static c200 | 4.4 | 3.6 | 1.22 |
| quote c512 | 142.0 | 125.4 | 1.13 |
| mix c512 | 103.5 | 97.7 | 1.06 |
| point c512 | 39.0 | 37.4 | 1.04 |

Everywhere else slang is already at or below Rust (batch: 1,369 MB vs
4,575).

## Evidence

**CCX33, server CPU per request** (cores / req/s, medians):

| scenario | slang | Go | Rust | slang / Go |
|---|---:|---:|---:|---:|
| quote c64 | 4,044 µs | 561 | 402 | 7.2x |
| quote c512 | 5,146 µs | 498 | 407 | 10.3x |
| mix c64 | 751 µs | 126 | 97 | 5.9x |
| point c64 | 145 µs | 70 | 45 | 2.1x |
| point c512 | 187 µs | 72 | 46 | 2.6x |
| http static c200 | 74 µs | 62 | 51 | 1.2x |

Quote is 15% of the mix and accounts for about 0.61 ms of the mix's
0.75 ms. Postgres CPU per point read: slang about 103 µs, Go 57, Rust 41.
Postgres is pinned to 2 cores, so slang reaches the database's ceiling at
half Go's throughput. slang's per-round numbers agree within about 3%.

**Local decode probe** (`dev` at `4bf2a02`, i5-8279U, 800 decodes of the
97 KB `quote_0.json` from `bench/suite/lib/gen_quote.py`, ABBA, two runs
each):

| | 1 worker, 1 task | 4 workers, 4 tasks |
|---|---:|---:|
| wall | 1,166-1,224 ms | 1,229-1,309 ms |
| user CPU | 1.15-1.18 s | 2.54-2.65 s |
| promoted / allocated | 973k / 3.21M (30%) | 2.63M / 3.21M (82%) |
| STW pause, minor + major | 0.18-0.21 s | 0.77-0.86 s |
| minors / majors | 244 / 24 | 187-195 / 23 |

**Four workers do no more work than one.** The world is stopped for about
two thirds of the run, and CPU per decode more than doubles: about 3.3 ms of
CPU per decode, the same order as the server's 4 ms per quote.

Open discrepancy: the probe decodes 200 bodies in 250-277 ms on one
worker; `next-steps.md` §7f records 81.9 ms for #290. Item 0.4 settles it.

## Causes, ranked by what they are expected to explain

### The collector (affects everything, quote most)
1. **Premature promotion.** The minor-GC trigger is one 512 KB budget for
   the whole process (`sl_gc_nursery_threshold`, `runtime/sl_gc.c`), a
   quote decode allocates about 262 KB, and any object that survives one
   minor is promoted. With four workers part-way through decodes, nearly
   everything they hold is promoted (82%). That garbage then needs majors,
   and a major marks the whole heap on one thread.
2. **One thread collects while the others spin.** Stopped workers loop on
   `sched_yield` (`sl_gc_ack_and_wait`, `sl_gc_stw_sync`). Mark and sweep
   run on one thread, so three of four cores burn doing nothing. That is
   why the server showed 3.95 cores busy.
3. **Waiting for every worker to reach a safepoint can last a whole
   decode.** `json.decode` has no safepoint (its comment in
   `runtime/sl_json.c` says so), and a GC request never triggers
   preemption. The ticker only preempts tasks past their 10 ms quantum.
4. **Two shared atomics per allocation.** `sl_gc_publish_bytes` does two
   `fetch_add`s on process-wide counters on every allocation. The comment
   above `SL_GC_PENDING_BATCH` says publishing is batched every 32
   allocations; the code publishes every one.
5. **Every collection does per-object and per-task work.** Each minor
   rebuilds a hash set of all young objects, sweeps a linked list of them,
   and walks every parked task three times (512+ at 512 connections).
6. **`malloc_trim(0)` runs inside every major's stop on Linux**,
   unmeasured.
17. **Majors are paced by all allocation, not by old-generation growth.**
    `sl_gc_bytes_since_collect` counts every byte allocated, so a major
    (a full-heap mark on one thread) runs every 8 MB even when nothing is
    promoted. Found in 0.4: 200 decodes, 6 objects promoted, 6 majors. On
    the server that is a full stop every ~30 quote requests.
7. **Lists of `int` and of value structs are traced word by word as
   possible pointers** (`sl_gc_trace_arr_range`, `runtime/sl_containers.c`;
   maps likewise). Batch's multi-million-entry `[int]` tables pay a set
   lookup per word on every major, and value-struct lists (item 2.1) would
   too.
18. **Resuming a parked task is O(parked tasks) under the global GC
    mutex.** `sl_task_resume` unlinks the task from `sl_parked_tasks`, a
    singly linked list, by walking it while holding `sl_gc_mu`. At 512
    connections every wakeup walks up to 512 entries under the lock
    every collection also needs. (Found during 1.1. Measured and fixed
    2026-10-07: it was what halved point and mix at 512 connections;
    doubly linked, point c512 6,553 -> 13,332 req/s, mix 6,107 -> 8,604.)
19. **`SLANG_WORKERS=N` runs tasks on N+1 threads.** main's own thread
    joins the pool after main's task first switches out, on top of the N
    workers. The CCX33 runs set `SLANG_WORKERS=4` on 4 pinned cores, so 5
    threads competed for them, and every stop waits for 5. (Found during
    1.1; to be decided with 1.4.)

### The `pg` driver (point, and the mix's database rows)
8. **Pool waiters poll every 2 ms** (`POOL_POLL`, `acquire` in
   `stdlib/pg/pg.sl`): no wait queue, no wakeup on release. At 512
   connections against a 64-connection pool, about 450 tasks poll in a
   lottery. That fits point-512's p99 of 143 ms against Go's 16 ms.
9. **A probe syscall on every acquire, under the pool lock**
   (`net.idle_alive`, a `recv(MSG_PEEK)`). pgx probes only connections
   idle for more than 1 s.
10. **No prepared statements and text results.** Postgres re-parses and
    re-plans every query. pgx caches statements and reads binary results.
11. **Query messages built from about 12 concatenations** (`extended`).

### HTTP and JSON, per request
12. **`http.read` re-parses the head on every partial `recv`.** A 110 KB
    body arrives in several reads, and each one allocates a `WireHead` and
    copies the header block.
13. **The body is zeroed, then copied.** `sl_gc_alloc` zeroes everything.
14. **2,000 heap objects where Go has one array.** `[QuoteItem]` is 2,000
    separate `gc struct`s; Go decodes into one contiguous `[]QuoteItem`.
    slang's value structs already live inline in lists, but `json.decode`
    accepts only `gc struct`.
15. **Encode builds a `str`, then copies it into the response.**

### Memory
16. **Per-connection buffers sized for the largest body.** The api program
    gives every connection a 300 KB read arena and a 64 KB response arena
    (`bench/suite/api/slang/main.sl`, `serve`), because `http.read` refuses
    a body larger than its buffer. That's where quote-512's RSS goes.

1-6 also explain the mix's latency at a light load (p50 54 ms at 2,000
req/s with half the cores idle): every stop triggered by a quote freezes
the point reads in flight with it.

## Rules for every item

- **Memory gate:** peak RSS for quote, mix and point at 64 and 512
  connections and at both fixed rates, before and after. No item moves a
  row out of Rust's league (1.10x), and no item makes a row worse by more
  than the run-to-run spread unless the gain it buys is recorded beside
  it.
- **Speed gate:** ABBA order, medians with raw values. Throughput, p99
  from `bench/latgen` (not wrk), CPU per request, on 4 workers. A delta
  smaller than the spread is noise.
- **Correctness:** a test that fails on the old code. Full `make test`.
  `SLANG_GC_VERIFY_MINOR=1 SLANG_GC_NURSERY_KB=16` with 0 missed, also
  under forced async preemption (`SLANG_PREEMPT_QUANTUM_MS=1
  SLANG_PREEMPT_TICK_MS=1`). A linux-arm64 CI dispatch for every
  `runtime/` or codegen change.
- **Runtime rules stand:** thread-locals only through accessors, libc
  bracketed, no GC allocation under a mutex, no safepoint between an
  allocation and the stores that initialize it.
- **Allocation budgets** in `tests/run_tests.sh` only go down.

## Phase 0: measure (no behaviour change)

- [x] **0.1 Split each pause into its parts.** `SLANG_GC_STAT` now prints,
  per kind, totals for time-to-safepoint, harvest, set build, mark, sweep
  and tail (page prune, trim), plus the longest time-to-safepoint. First
  reading, decode probe, 200 decodes, `dev`:

  | part | 1 worker | 4 workers |
  |---|---:|---:|
  | minor: time-to-safepoint | 0.08 ms | **67 ms (longest 10 ms)** |
  | minor: set build | 12.4 ms | 12.8 ms |
  | minor: mark | 2.9 ms | 9.7 ms |
  | minor: sweep | 6.0 ms | 4.5 ms |
  | minor: tail | 2.2 ms | 9.5 ms |
  | major: sweep | **24.4 ms** | **42.8 ms** |
  | major: set build | 7.2 ms | 17.3 ms |

  Order of attack: time-to-safepoint (1.1), then the major sweep (which
  walks every promoted-then-dead object: 1.2, 1.9), then set build (1.5).
- [x] **0.2 Count work per minor:** tasks walked by the harvest and
  remembered entries traced, in the same output. (Promotion was already
  counted.)
- [x] **0.3 Local harnesses, checked in under `bench/`** (point and mix
  against Postgres are deferred to Phase 3, which is their only user):
  - `bench/gc/decode`: the decode probe;
  - `bench/gc/ab.sh <slangc-A> <slangc-B>`: two builds in ABBA order. It
    runs the probe at 1 and 4 workers, then the real api server's
    `POST /api/quote` under `latgen` (new `-body-file` flag) with no
    database. It reports medians and raw values.

  Laptop noise, measured by A/B with two identical builds: single rounds
  differ by up to 1.6x (decode1 282 vs 465 ms). Decisions use
  `ROUNDS=3` and need an effect clearly larger than that spread.
  Baseline (`dev` at `4bf2a02`, 4 workers, 64 connections): about
  370-550 quote req/s, 6.5-10 ms of CPU per request, 41-47 MB RSS.
- [x] **0.4 The 81.9 ms vs 250-277 ms discrepancy: settled.** #290's
  harness dropped each decode result straight away. The probe walks the
  items, as the api handler does, so a pending minor runs while the whole
  tree is live and promotes it. Same build, one worker, 200 decodes:

  | | promoted | peak RSS | instructions | wall |
  |---|---:|---:|---:|---:|
  | result walked (`USE=1`) | 244,250 | 11.5 MB | 1.19 B | 304 ms |
  | result dropped (`USE=0`) | 6 | 3.3-3.8 MB | 0.83 B | 136 ms |

  #290's 758 M instructions match the dropped case. A real handler pays
  2.2x the time and 3x the RSS on one worker. #290's number was the best
  case, not a regression since. The same runs show cause 17: 6 majors
  with 6 objects promoted.

## Phase 1: make four workers worth four

- [ ] **1.1 Bound time-to-safepoint.** If the world has not stopped within
  about 50 µs, send the existing async-preempt signal to every worker that
  has not acknowledged. Stopped workers spin briefly, then block on a
  futex or condition variable instead of `sched_yield`. Target: the
  safepoint wait drops from up to a decode to the signal's latency.

  **Status (2026-10-04): built and measured, not landed.** Branch
  `perf/gc-ttsp` holds five parts: a kick (async-preempt every running
  task after 50 µs at the rendezvous), a preemption slot for main's
  thread (it had none), an allocation-entry yield (85% of kicks were
  declined inside the allocator's bracket), a CPU pause instead of
  `sched_yield` (Darwin's depresses the collector's priority for a
  quantum), and stopped workers sleeping on a condition variable. Minor
  time-to-safepoint on the 4-worker decode probe fell from 67 ms total
  (10 ms worst) to 1.5-1.9 ms (0.05-0.2 ms worst), and quote CPU per
  request from 6.0 to 3.3 ms. But on this laptop, ABBA against `dev`:

  | variant | quote req/s | quote RSS | CPU/req |
  |---|---:|---:|---:|
  | all five parts | -9% | +42% | -46% |
  | kick + pause-spin | -22% | +16% | +29% |
  | kick + sleep | -17% | +13% | -42% |
  | kick + yield + spin | -17% | +42% | +21% |

  Throughput and RSS gates fail, so none of it lands yet. The yield is
  what costs RSS (more half-built requests live at each minor, more
  promoted). The load generator shares this laptop's cores, and macOS
  treats spinning, sleeping and `sched_yield` very differently from the
  CCX33's pinned Linux cores, so the waiting strategy is re-measured in a
  Linux container with pinned CPUs before it is decided. 1.9 and 1.2 go
  first: fewer collections shrink every per-collection cost, this one
  included. Found on the way and landed separately (`fix/preempt-libc-
  deadlock`): an allocator deadlock reachable from `dev` (todo.md), and
  the owner-generation read in `sl_gc_alloc_owned`.

  **Update (2026-10-05): the kick, measured alone on Linux, still
  loses.** With stopped threads asleep (#314), trim outside the pause
  (#315) and major pacing (#316), the kick alone (async-preempt every
  running task after 50 us at the rendezvous, quantum test skipped while
  a stop is requested) against `dev`, quote ABBA x3 in the Linux
  container: 3,414 -> 3,317 req/s, p99 51 -> 73 ms, CPU even. Kicked
  tasks are requeued behind others, so the requests they carried wait
  longer. Time-to-safepoint (~0.5 ms a collection, mostly a worker
  inside a whole json.decode) stays the largest fixed cost per
  collection; the next try is a poll inside the generated decoders that
  acks without giving up the worker, not a signal.

  **Nursery ceiling raised (2026-10-05, owner's decision): 2 MB a
  worker, at most 16 MB.** Linux quote ABBA x4 against `dev`: 3,616 ->
  4,037 req/s, p99 43 -> 38 ms, CPU per request 973 -> 957 us, peak RSS
  31.2 -> 36.6 MB. Against Go in the same container, ABBA x4: Go 3,775
  req/s, slang 3,667 (last three rounds within 1%), p99 101 vs 43 ms,
  CPU per request 1,442 vs 1,058 us, RSS 80 vs 33 MB. macOS quote: +2%
  req/s, p99 even, CPU +4.7%, RSS 22.4 -> 27.6 MB.

  **In-place decoder stops (parked, branch `perf/json-decode-poll`).**
  Generated list decoders checked every 64 elements for a pending
  collection and stopped where they were, the task's stack below its
  last safepoint scanned conservatively (callee-saved registers spilled
  by inline asm: `__builtin_unwind_init` spilled nothing under Apple
  clang, and the verifier caught the list being decoded swept). Linux:
  time-to-safepoint -90%, quote p99 61 -> 49 ms, +4% req/s; but a
  collection mid-decode finds the partial result alive, and two of them
  promote it: the decode probe promoted 104,352 objects instead of 12
  and ran 14% slower. Not landed.
  Followed up (2026-10-05): bounding the conservative scan to the
  decoder's own frames (excluding stale slots in the slang caller's)
  left promotions at 52-62k, so the partial results are genuinely live,
  and precise decoder roots would not help. Not aging young survivors
  in a minor that stopped a decode in place cut promotions to 25-39,
  but the decode probe was still 20% slower (ABBA x3, 247 -> 296 ms):
  a collection that stops a decode finds its partial result alive and
  marks it, which costs more than the ~0.4 ms of waiting it saves.
  Parked for good unless decodes get much longer than a collection.

  **Owner decision (taken above): nursery size.** Each collection pays that
  fixed ~0.5 ms, so fewer collections help. Quote ABBA x3, Linux, fixed
  nursery against the adaptive one (which tops out at 1 MB a worker, 4
  MB here): 8 MB +7% req/s for peak RSS +7 MB (28.9 -> 35.9); 16 MB
  +12.7% for +18.5 MB (25.3 -> 43.8). Go's RSS on the same run is ~80
  MB. Not taken without the owner: memory is the product, and raising
  the adaptive ceiling (sl_gc_nursery_set_max) to 2 MB a worker would
  be the 8 MB row.

  **Update (2026-10-05): the waiting half landed, after a Linux
  measurement.** In a Linux container (x86_64, Docker on the dev Mac,
  `perf`), the quote server spent 60% of its CPU in the stopped
  threads' `sched_yield` loop and the kernel scheduling around it
  (reschedule IPIs in a VM); macOS hid it. Stopped threads now spin ~256
  pause instructions, then sleep on a condition variable that the
  collector broadcasts when it lowers the stop or starts a chained
  cycle. Quote ABBA x3, Linux: 1,086 -> 2,870 req/s, CPU per request
  4,619 -> 1,166 us, p99 199 -> 54 ms, RSS 29.2 -> 27.3 MB. macOS:
  3,528 -> 3,585 req/s, CPU per request 1,305 -> 863 us, p99 48.6 vs
  49.5 ms. The kick and the allocation-entry yield stay unbuilt.

  **Update (2026-10-04): not needed for now.** After 1.10, 1.2 and 1.3
  the minors are fewer and their walk shorter, and minor time-to-safepoint
  on the quote server is about 0.6 ms per collection, 1 ms at worst,
  without any kick. Reopen only if the CCX33 re-run (Phase 9) shows the
  rendezvous in the tail.
- [x] **1.2 Stop promoting in-flight request data: promotion after two
  survivals.** Chose (b): it fixes the one-worker case too (30% promoted
  there), where (a) would only have moved the boundary. A first survival
  ages an object (`gen` 2, still young, still on the young list); a
  second promotes it. Two consequences made it sound, both caught by the
  verifier: (1) a promoted object can point at one that is only aging,
  so every promoted object with a tracer is remembered for the next
  minor; (2) a remembered object whose trace meets a first-survival
  child stays remembered, and a list or map leaves its frontier at the
  first such position (`sl_gc_trace_arr_minor`/`_map_minor`), not at
  the end -- restoring it to where the trace started instead made a
  growing container retrace from there every minor (1M-entry build 2.7
  s -> 11.9 s). Decode probe, 400 decodes:

  | | promoted | peak RSS | major pause | wall |
  |---|---:|---:|---:|---:|
  | 1 worker, `dev` | 484,490 | 12.9 MB | 44 ms | 498 ms |
  | 1 worker, aging | 6 | 6.7 MB | 9 ms | 427 ms |
  | 4 workers, `dev` | 1,425,436 | 24.3 MB | 130 ms | 380 ms |
  | 4 workers, aging | 12 | 9.5 MB | 26 ms | 293 ms |

  Minor pauses rise (aged objects are marked twice: 39 -> 69 ms, 80 ->
  144 ms) and the 1M-entry cache build costs 12% more (2.75 -> 3.09 s,
  each new position traced about twice). Majors are still paced by all
  allocation, so their count is unchanged; 1.9 removes them now that
  almost nothing is promoted. Test: `gc_promotion_budget` (30.7% ->
  0.28% promoted, pinned at 1% in "promotion budgets"; stress- and
  verifier-listed).

  **1.2a, adaptive nursery: done (2026-10-04).** The nursery doubles,
  up to 1 MB per worker (8 MB cap), after a minor that cost more than an
  eighth of the time since the previous one *and* found more than an
  eighth of the nursery live; it halves when either falls under a
  sixty-fourth / thirty-second, never below 512 KB.
  `SLANG_GC_NURSERY_KB` still fixes it. Measured first with a fixed
  nursery on the quote server (4 workers): 512 KB 1,480/1,451 req/s, p99
  100/117 ms, 32/34 MB; 4 MB 1,851/1,801 req/s, p99 80/76 ms, 29/28 MB;
  8 and 16 MB no better. A fixed 4 MB costs the compute benchmark 7 ->
  12 MB for no speed, and pause share alone grew a tight loop of short
  strings to 8 MB; the survival condition keeps both at 512 KB. Test:
  "nursery adaptation" in `tests/run_tests.sh` (`gc_promotion_budget`
  must grow, `gc_nursery_small` must not). ABBA against `dev`, quote
  server: 1,453 -> 1,848 req/s, p99 101 -> 78 ms, p99.9 146 -> 85 ms,
  CPU per request 3.36 -> 2.66 ms, RSS 37.5 -> 28.7 MB. Decode probe: 4
  workers 21% faster but 9 -> 15.5 MB (its nursery grows to 4 MB); 1
  worker 6% slower, 6.1 -> 8.1 MB.

  The options considered:
  - (a) nursery budget scaled with the workers (512 KB each, capped);
  - (b) promote after surviving two minors. The age fits in the `gen`
    byte, so the header stays 40 bytes; audit every `gen == 0` and
    `gen == 1` test, the write barrier's included.

  Target: under 10% promoted on the 4-worker probe (82% today), majors
  down several times, RSS within the gate.
- [x] **1.3 Count allocated bytes per worker.** Each worker adds its
  allocations to an accumulator in its own state and publishes to the
  shared trigger counters every 16 KB (`SL_GC_PUBLISH_BATCH`); a trigger
  is late by at most a batch per worker. Per worker, not per task:
  hundreds of parked connections each holding back a batch would delay
  a minor without bound. The fixed-threshold test modes still publish
  every allocation. The per-task byte counters went with it. ABBA
  against `dev`: quote 1,817 -> 2,092 req/s, CPU per request 2.68 ->
  2.34 ms, p50 36 -> 29 ms (p99 76 -> 82 ms and RSS 29.0 -> 29.9 MB,
  both inside the run-to-run spread); decode probe 9% (4 workers) and 6%
  (1) faster.
- [ ] **1.4 Stopped workers help collect.** Parallel sweep first: each
  worker already owns its pages, so the split is natural. Then parallel
  mark, with per-worker work lists and an atomic mark claim.
  **Parallel sweep landed 2026-10-07** (todo.md R4): minor sweep + tail
  at mix c512 1.74 -> 0.74 ms. Mark (0.9-1.0 ms) and the rendezvous
  (0.5-0.7 ms) are now the largest phases; parallel mark is what is
  left of 1.4.
- [x] **1.5 Recognize paged objects by their page; list only the
  rest.** A minor's object table (`sl_gc_set`) listed every young
  object: a walk of the young list and a hash insert each, about half of
  every minor (20-26 ms of 49-53 ms on the 4-worker decode probe, the
  inserts more than the walk). A paged object needs no entry: its 16 KB
  page is found from the pointer, checked against a small registry of
  live page bases (a conservative word can be any address, so the page
  header is read only for a registered base), and the page's start
  bitmap says whether an object begins there (`sl_gc_known`). Only
  unpaged objects stay in the table; a minor's are each worker's
  allocations since the last collection (`mbuf`) plus the unpaged ones
  that stayed young (`sl_gc_young_m`), with no walk. Majors and the
  verifier still walk both lists, inserting only the unpaged. The
  minor mark now drops old objects before marking them (they are
  recognizable through their pages now). Minor set build 19-20 ms ->
  1.5-1.8 ms. Quote server, ABBA: 3,077 -> 3,864 req/s, p99 47 -> 39 ms,
  CPU per request 1.60 -> 1.27 ms, RSS 24.7 -> 20.7 MB. Probe with plain
  struct items, 4 workers: 14% faster; `gc struct` items, 1 worker: 7%
  faster; **`gc struct` items, 4 workers: 12-15% slower**, not explained
  (same fallback rate, same collection counts, no new hotspot in a
  profile; recorded in `todo.md`). The young list is still walked by the
  sweep: that is 1.5's other half, the page sweep.
  **Page sweep landed 2026-10-07** (todo.md R4): the young, pending and
  retired lists are gone, pages are swept by their start bitmaps, and a
  major's set build no longer walks promoted paged objects. Minor sweep
  at 512 connections -40% (mix) to -60% (point); major set build 2.3 ->
  0.02 ms.
- [ ] **1.6 Minors skip tasks with nothing young.** A task that has not
  run since the last minor holds only old values, because that minor
  promoted everything it held. Audit every place that hands a value to a
  parked task first: channel receive, `join`, `select`.
- [x] **1.7 `malloc_trim` outside the stop**, and only after a major that
  freed a lot. Decide it with §7c (macOS keeping freed pages).
  Landed (2026-10-05), after a Linux profile: the major's tail was
  0.75 ms, most of it this, and on the quote server a major came after
  every minor. The trim now runs after the pause, at most every 100 ms.
  Quote ABBA x3 in a Linux container: 2,619 -> 2,976 req/s, CPU per
  request 1,261 -> 1,144 us, p99 63 -> 57 ms, peak RSS 21.8 -> 25.8 MB
  (glibc keeps freed memory up to 100 ms longer; taken: the owner
  accepted RSS for throughput here, and Go's is 75 MB). Trimming after
  every major outside the pause was -14% req/s; every second, about the
  same speed for +4.6 MB.

- [ ] **1.8 Precise tracing for lists and maps of non-pointers.** The
  compiler knows the element type, so it tells the runtime: `[int]` and
  `[f64]` are not traced at all, and a value struct gets a pointer-offset
  map. This removes cause 7 and is needed before 2.1 can land without a
  tracing regression.
- [x] **1.9 Pace majors by old-generation growth** (cause 17).
  **Landed (2026-10-05), measured on Linux.** A major now comes after
  the live-paced threshold of promoted bytes, or every 16 minors. The
  minor bound is what the earlier attempt lacked: with promotion alone,
  dead promoted objects pin young pages (the collector does not move)
  and peak RSS grew 7 MB. Linux quote ABBA (K = minors per major): 8
  +4% at equal RSS, 16 +9% for +0.8 MB, 32 +10% for +1.6 MB; against
  `dev` after 1.7 landed, 5 rounds, +2.6% req/s (4 of 5 rounds ahead),
  CPU even, RSS 25.3 -> 26.3 MB. 4-worker decode probe, Linux: majors
  94 -> 11, wall ~1,185 -> ~1,067 ms, faster in every round. macOS quote:
  +1.6% req/s, p99 33.6 -> 31.7 ms, RSS +0.7 MB.
  Earlier note, kept for the record:
  **Built and measured, parked (2026-10-04, branch
  `perf/gc-major-pacing`).** It removes every major on the decode probe
  (11 -> 0; 4-worker wall -17%, RSS 9.2 -> 6.0 MB), but on the quote
  server, the target, it does nothing for throughput or CPU and the tail
  and RSS lean the wrong way. Old-generation targets tried, quote server
  ABBA against `dev`: live (8 MB floor) -3% req/s, RSS +35%; live/2 (2 MB
  floor) req/s even, p99 -12%, RSS +6%; live/4 (1 MB floor), 3 x 15 s
  rounds, req/s even, p99 +15%, p99.9 +41%, RSS +6%. The server's majors
  are cheap (small old heap) and frequent ones keep dead old objects
  from pinning young pages, so pacing by promotion gives nothing there.
  Revisit if majors show up in a profile again. Count
  promoted bytes, plus objects born old, toward the major threshold, not
  every allocation. The live-heap pacing (next major after as many bytes
  as survived) keeps the same form, measured on what actually reaches the
  old generation.

- [x] **1.10 Allocation stops walking full pages** (found by profiling
  the quote server after 1.2). Once every young page of a worker was
  full and its 64-page cap reached, each allocation still walked all of
  them, inside the allocator's preempt bracket, before falling back to
  malloc: on `dev` 74% of the 4-worker decode probe's allocations fell
  back, each after that walk. A per-worker `exhausted` flag, cleared by
  the sweep-end prune (no claim can succeed before it), sends them
  straight to malloc. ABBA against `dev` (with 1.2): quote 1017 -> 1291
  req/s, p99 195 -> 115 ms, p99.9 306 -> 133 ms, CPU per request 4.06 ->
  3.20 ms, RSS 40.8 -> 33.9 MB; decode probe 548 -> 348 ms (1 worker),
  351 -> 317 ms (4). Checked under `SLANG_GC_PAGE_DEBUG` with the path
  exercised (12,936 fallbacks, no violations).
- [x] **1.11 Young pages hold a whole cycle** (found profiling the probe
  after 2.6). 1.10 made the fallback cheap; this removes it. The 64-page
  cap was sized for the fixed 512 KB nursery, and 1.2a's adaptive nursery
  reaches 1 MB a worker, so a third of the 1-worker probe's allocations
  still went to malloc and were freed one by one in the minor sweep. A
  worker may now hold 512 pages (the 8 MB largest nursery: the trigger is
  global) and keeps 128 empty ones across a sweep; keeping 64 re-allocated
  ~40 aligned pages a cycle and doubled peak RSS on macOS. ABBA x4,
  4,000 decodes: 1 worker 2,356 -> 1,753 ms, peak RSS 10.3 -> 5.7 MB; 4
  workers 4,983 -> 4,170 ms, 19.2 -> 16.8 MB. The quote server is
  unchanged: it falls back only while warming up and holds ~50 pages a
  worker after, under both caps.

**Exit gate:** the 4-worker probe runs at least 3x faster than 1 worker
(1.0x today), and the local quote server's CPU per request is within 1.3x
of its 1-worker number.

## Phase 2: cheaper per-request work

- [x] **2.1 `json.decode` and `json.encode` of value structs**, and of
  lists and maps of them, decoded inline (decided 2026-10-04). Done: a
  plain struct is decoded straight into the caller's storage (a binding,
  a list's or map's slot) and encoded through `.`; `bench/suite/api/slang`
  uses `struct QuoteItem`. The three `fail_json_plain_struct_*` tests
  became positive `json_plain_struct_*` tests. Needed the value-struct
  tracing and rooting fix first (todo.md: lists of value structs lost
  their strs). Quote server, ABBA, `dev` with `gc struct QuoteItem`
  against this with `struct QuoteItem`, responses byte-identical: 2,019
  -> 2,829 req/s, p99 78 -> 54 ms, p99.9 106 -> 76 ms, CPU per request
  2.39 -> 1.70 ms, RSS ~30 -> ~25 MB.
- [ ] **2.2 Frame the head once per request.** Keep the parsed head across
  partial `recv`s of one request, without keeping a `WireHead` alive across
  the park (the promotion trap `http.read`'s comment describes).
- [x] **2.3 A runtime-internal allocation that skips zeroing** --
  landed narrowly (2026-10-05): `sl_gc_alloc_leaf_uninit` /
  `sl_bytes_alloc_uninit` for pointer-free leaves one memcpy fills (the
  JSON string fast path, strings' copies, `sl_bytes_new`, the network
  receive copy). Linux single-task decode probe ABBA x3: 896 -> 864 ms;
  quote server even (4,828 vs 4,843 req/s). Earlier note:, for
  callers that overwrite every byte: the body copy, `to_bytes`, list and
  string growth.

  **Dropped (2026-10-04): measured neutral twice.** Skipping the zeroing
  for the body copy and string growth, quote ABBA against `dev`: CPU per
  request 2,375 vs 2,376 µs, 2,062 vs 2,056 req/s, RSS 28.5 vs 28.9 MB.
  The difference is inside the run-to-run spread. Not investigated
  further: the profile's `bzero` share was not attributed to callers.
- [ ] **2.4 Attribute what is left by call site**, using the
  instrumented-allocator method from `next-steps.md` §5, and fix by count.
- [ ] **2.5 New JSON APIs** -- dropped (2026-10-05, owner's decision on
  measurement). DWARF call graphs of the quote server in a Linux
  container: the request body copy `decode_view` would remove was ~1% of
  CPU (0.6% zeroing it, the copy itself less), and the response encode
  `encode_into` would remove under 0.1%. Not worth permanent API. The
  same profile found 11% in libc memcmp from the decoders' key test
  (fixed, #321) and 2.7% clearing string allocations (2.3 below).
  Original proposal: (in scope as of 2026-10-04; `note.txt` had them
  out). Proposed, signatures to be confirmed with the owner before code:
  - `json.encode_into(w: &mut wire, off: int, v: T) -> int`: encode
    straight into the response wire, with no intermediate `str` (cause
    15). It returns the true length, so it can size its own wire the way
    `http`'s `emit` does.
  - `json.decode_view(buf: wire, lo: int, hi: int) -> result[T, str]`:
    decode straight out of the read buffer, with no body copy.
    `http.read` would expose the body's range, and the copy then happens
    only for a handler that keeps the bytes.

- [x] **2.6 Integers decode in one pass** (found by profiling the quote
  handler). `json.decode` into an integer field validated the number,
  then parsed its text again. A plain integer token of up to 18 digits
  is now scanned and converted in one pass; fractions, exponents and
  longer numbers keep the exact two-pass path, and
  `tests/json_int_exact` checks that both agree, error offsets included.
  Single-task decode probe, ABBA, 5 rounds of 20,000 decodes: 11,812 ->
  11,011 ms (-6.8%), with no overlap between the two sets of runs.

- [x] **2.7 Struct decoders try the expected key first** (found
  profiling the quote server after 1.11: `sl_jd_key` was the hottest
  runtime function). Keys nearly always arrive in declaration order, so
  the generated decoder tries the next field as a literal (`"sku"` and
  its colon, one memcmp) and only on a miss scans the key and compares
  it with every field. `tests/json_key_order` pins out-of-order,
  duplicate, escaped and prefix keys; old and new print the same.
  Decode probe ABBA x5: 4,035 -> 3,312 ms (faster in every round); quote
  server ABBA x3: 3,904 -> 4,237 req/s, CPU per request 1,219 -> 1,155
  us, p99 and RSS unchanged.

**Exit gate:** single-thread CPU per quote request at or below Go's
(about 0.56 ms on the CCX33), measured on the same host as Go.

## Phase 3: the `pg` driver

- [x] **3.1 FIFO wait queue in the pool.** Waiters park and are woken on
  release, so the 2 ms poll goes away. Include a fairness test. Measure on
  point-512 p99.
  Landed: a release hands its connection to the oldest waiter, a freed
  slot goes to the oldest waiter to dial, and one reaper task per pool
  (alive only while tasks wait) times waiters out; `select` has no
  timeout arm. Local point, 512 clients on a 64-connection pool, Postgres
  in Docker, ABBA x3: p99 369 -> 116 ms, p99.9 563 -> 154 ms, 6,187 ->
  7,099 req/s, CPU per request 288 -> 229 us; p50 57 -> 70 ms (everyone
  waits about equally now). Peak RSS 19.3 -> 24.7 MB, all of it the
  adaptive nursery (1.2a) growing with the higher allocation rate: with
  `SLANG_GC_NURSERY_KB=512` RSS is 15.9 vs 16.1 MB and p99 still 420 ->
  216 ms. Revisit with 1.9 if the CCX33 run shows the memory matters.
- [ ] **3.2 Probe only connections idle for more than 1 s, outside the
  lock**, as pgx does.
  Built, parked on branch `perf/pg-probe-idle`: neutral on the laptop
  (CPU per request 153.5 vs 153.3 us at 64 clients, 226 vs 226 at 512;
  one saved ~1 us syscall). Re-measure on the CCX33 before landing.
- [x] **3.3 Build each query message with one builder.** Done 2026-10-07 (perf/pg-alloc): 115 -> 41 allocations a cached query; see todo.md R5.
- [x] **3.4 Per-connection prepared-statement cache** (landed in #312) (decided 2026-10-04:
  reverses the driver's "deliberately no named prepared statements"; update
  that comment). Bounded LRU per connection. On error `0A000` ("cached plan
  must not change result type"), drop the statement and retry once.
  Statements are closed when a connection is closed or evicted.
  Landed: `query` keeps the 256 most recent statements per connection
  (`statement_cache_capacity` in the url, 0 off); a first use sends a
  named Parse in the same round trip; evicted statements and failed
  first uses are closed by a Close sent ahead of the next query.
  `0A000` and `26000` re-prepare and retry once, outside a transaction
  only; `DEALLOCATE ALL` / `DISCARD ALL` empty the cache. Local point,
  64 clients, ABBA x3: Postgres CPU per request 502 -> 206 us, 7,556 ->
  9,249 req/s, p99 22.9 -> 14.3 ms; slang CPU 157 -> 155 us. At 512
  clients Postgres CPU 472 -> 223 us.
- [ ] **3.5 Binary result format** -- built and parked (2026-10-05,
  branch `perf/pg-binary-results`): a cached statement's later runs read
  int2/int4/int8, bool and bytea columns in binary (floats stay text:
  get_text must not change). On a 100-row orders query, slang CPU per
  request -6.6% and +7% req/s locally (slang-bound), but Postgres CPU per
  request rose 7% (644 -> 690 us, repeated, no overlap). Postgres is the
  ceiling on the CCX33's database workloads, so it would lower
  throughput there. Original item: for the types the driver decodes
  (`int2/4/8`, `bool`, `float4/8`, `bytea`; text stays text). In scope as
  of 2026-10-04 (`note.txt` had it out). Every width and length from the
  server is bounds-checked, as the driver's limits section requires.

Target: Postgres CPU per point read at or below Go's 57 µs (Rust shows 41
is possible). Point throughput past Go's needs less database CPU per
query than pgx, because at 2 Postgres cores the database is the ceiling.

## Phase 4: memory

- [ ] **4.1 Read buffers that grow for a large body**, instead of each
  connection holding the largest body's worth. `http.read` takes a body
  beyond its wire into a separate allocation capped by a size limit (a
  security boundary: cap it, refuse past it, never guess). The api program
  drops to a small per-connection wire. Target: quote-512 and mix-512
  inside Rust's league.
- [ ] **4.2 The fixed-rate mix rows** (1.41x and 1.28x Rust): attribute
  their RSS (heap, page retention, arenas, malloc) after Phases 1-3, then
  fix what the attribution names.
- [ ] **4.3 http static c200** (4.4 MB vs Rust 3.6): attribute and fix.

## Phase 5: collector redesign track

In scope as of 2026-10-04. Each item starts with a design note in
`runtime/` and a measurement saying what Phases 1-4 left on the table. It
must answer the objection `runtime/GENERATIONAL_GC_HANDOFF.md` recorded
against it, and land only if the result clears both gates.

- [ ] **5.1 Moving (mostly-copying) nursery.** The handoff's objection: a
  conservative candidate word cannot be rewritten. The answer to evaluate
  is Bartlett-style mostly-copying. Any young object a conservative root
  (an async-preempted stack, a C runtime frame) may reference is pinned in
  place and promoted where it stands; everything reached only precisely is
  evacuated. Also to resolve:
  - interior pointers (`sl_bytes`' inline `ptr`);
  - pointers handed to C (`extern`, `rawptr`), which must pin;
  - the page bitmaps of 1.5.

  The win to measure: bump allocation into contiguous space, minor cost
  proportional to survivors rather than deaths, and no young
  fragmentation (RSS).
- [ ] **5.2 Parallel minors with per-worker nurseries.** Each worker
  marks and sweeps (or evacuates, with 5.1) its own nursery during a
  shared stop, like OCaml 5. Then the further step to evaluate: minors
  local to one worker, with no global stop, which need
  - every young object promoted the moment it escapes (stored into an old
    or shared object, sent on a channel, passed to `spawn`, or `join`ed);
  - an answer for a task moving between workers while holding young
    pointers.
- [ ] **5.3 Concurrent marking for majors.** Minors stay stop-the-world.
  The handoff's objections: a barrier on every pointer store, and extra
  heap headroom, which threatens the memory goal. Entry condition: after
  Phases 1-4, majors still show in p99 or p99.9. Measure the cost of a
  snapshot-at-the-beginning barrier on every store, and the RSS headroom,
  against the memory gate.

## Phase 6: batch

- [ ] **6.1 Profile on Linux** (`perf`). §7e's leaf-loop polls had
  already landed (#283) before the measured commit, so the 28.3 s (Go
  11.9, Rust 7.1, slang CPU 110.8 s vs Go 39.4) already includes them.
- [ ] **6.2 Precise tracing of the `[int]` tables** (1.8) and §7d's
  whole-map retrace when an existing map key is updated.
- [ ] **6.3 What the profile names next:** parsing, hashing, the merge.
  Keep the lead on memory: 1,369 MB against 4.5-6.0 GB for everyone else.

## Phase 7: LLVM backend evaluation (overrides AGENTS.md)

`AGENTS.md` §6 and `next-steps.md`'s notes say "Do not start an LLVM
backend". The owner put it in scope on 2026-10-04. The case to test is
not speed of generated code, since `cc -O3 -flto` already provides that.
It is **precise stack maps** (`gc.statepoint`). Those would replace the
safepoint roots arrays and the conservative scan, which removes
- the per-call root bookkeeping, and
- 5.1's pinning problem.

- [ ] **7.1 Measure first:** the share of CPU spent on safepoint
  enter/exit and roots arrays in the api and batch programs (`perf` on
  Linux, disassembly with `--keep-c`). No backend code unless that share,
  plus what 5.1 cannot do with pinning, is worth the build-time and
  maintenance cost, which must be recorded alongside it.
- [ ] **7.2 If it is worth it:** a design note covering build time
  (today about 97% of a build is `cc`), the frame guards, both
  architectures, and keeping the C backend as the reference.

## Phase 8: `bench/http` (overrides AGENTS.md)

`AGENTS.md` §6 says never edit `bench/http/main.sl` for an experiment: it
is the frozen ruler other bench scripts compare against
(`bench/http/README.md`). The CCX33 suite measures `bench/http_opt`, not
this file. In scope as of 2026-10-04.

- [ ] **8.1** Any edit is a deliberate re-baseline, not an experiment:
  measure the old ruler and the new one on the same host in the same
  session, record both in `bench/http/README.md`, and keep the old
  numbers labelled as the old ruler.

## Phase 9: prove it

- [ ] Re-run the full suite on a CCX33 with #287's configuration. Pass:
  both goals above, every row. Record it in `bench/RESULTS.md`.
- [ ] Before #287 merges, correct its description:
  - the "lowest peak RSS among all languages" claim (Rust is lower at
    c200);
  - the attribution of quote and mix to "JSON allocation and GC overhead",
    which that run did not measure;
  - say which of its two result directories is the smoke run.

## Decisions

Taken 2026-10-04:

- **Prepared statements in `pg`:** yes, reversing the documented choice
  (3.4).
- **`json` of value structs:** yes, including the benchmark program's
  switch to `struct QuoteItem` (2.1).
- **Memory bar:** no fixed MB cap. Every row stays in Rust's league
  (≤ 1.10x Rust, aiming for ≤ Rust), which also keeps slang below Go.
- **Scope widened:**
  - the collector redesign track (Phase 5);
  - pg binary format (3.5);
  - new JSON APIs (2.5);
  - the LLVM evaluation (Phase 7);
  - `bench/http` edits (Phase 8);
  - batch (Phase 6).

- **Rules updated to match Phases 7 and 8:** `next-steps.md`'s notes
  (here) and `AGENTS.md` §6 (local to each checkout; the file is
  gitignored) now allow both, under this plan's gates.
- **Working mode (2026-10-04):** items are worked autonomously, one PR
  each against `dev`, merged once the definition of done holds. Every
  decision taken along the way is written into its PR and beside its
  ticked item here. Laptop runs are the comparison used to move on; the
  CCX33 re-run (Phase 9) is the verdict.

Still to confirm before their code starts:

- the exact JSON API signatures in 2.5. If no answer is available when
  2.5 is reached, build the proposed signatures and record that choice.
