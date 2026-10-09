# next steps

Work top to bottom, one item at a time; tick items as they land. Items 2
and 3 are being worked now.

The API performance and memory work after the CCX33 run (#287) has its own
plan: [`fix-gc.md`](fix-gc.md). It is worked ahead of this queue.

Everything finished is cleared from this file to keep it short. The full
write-ups — why each design was chosen, what was measured, which controls
caught what — are in git history and the PR descriptions:

- before v0.2.0: `git show eeefce1:next-steps.md`
- Linux CI (x86_64 and arm64), OpenSSL discovery, `slangc test`, chunked
  request bodies, methods sharing a name with a package function, and the
  Postgres driver: `git show f9680d1:next-steps.md`

API speed audit (2026-10-09): quote/mix baselines, the Linux profile, and the
decoder experiment are recorded in [`SERVER_SPEED_AUDIT_PRD.md`](SERVER_SPEED_AUDIT_PRD.md).
The decoder experiment did not pass the performance gate. Route-level PG
timing support is in [`bench/PG-ROUTE-PERFORMANCE-PRD.md`](bench/PG-ROUTE-PERFORMANCE-PRD.md);
run it on a host that passes the benchmark host check before selecting a
driver or scheduler change. Do not change arena sizes without evidence, since
Slang RSS was already below Go at c512.

A focused Go/Slang runner for the four PostgreSQL routes is prepared in
[`bench/PG-TARGETED-BENCHMARK-PRD.md`](bench/PG-TARGETED-BENCHMARK-PRD.md).
It uses the requested 4-vCPU/16-GB host, a 1M-user/20M-order seed, and ABBA
sampling. It is ready for the new VPS; no measurements have been taken there.

Runtime bugs and their investigations live in `todo.md`.

Landed since that clear-out (PRs #157, #159–#162, #164, #165, #168, #169,
#171, #173–#175): `io` (stdin, then terminal control: size, no-echo, raw mode, keys),
`flags`, method calls on any expression, the callee of an indirect call made
visible to every compiler pass, a use-after-free in the DNS resolver, a
Linux-only test timing assumption, the licence and community files, stable
table storage and one iterator over function bodies (generics PR 0), and an
entry guard for functions with a large C frame (a 700-call function died with
SIGBUS on clang), generic structs (generics PR 1), and three fixes found while
testing them: a `gc` struct literal nested in another did not compile, a
stack-boxed `gc` value's heap fields were never rooted, and `json` of a plain
struct failed in C instead of saying so.

Landed since (Sep 2026): `own T` box fields rooted and the first pass audit
(`tests/own_roots`, `tests/audit_roots`, `tests/escape_roots`); the ~5% SIGBUS
under amplified preemption (#233: the kernel's signal frame overwrote the
trampoline's resume slot) and the GC-minor crash found beside it (#232:
container buffers freed out from under a dead old owner); package names from
dotted directories (#235). Write-ups in `todo.md`.

Landed since (Oct 2026): `json.decode` nesting depth costs heap, not C
stack, up to the 512-level cap, for recursive target types too
(`tests/json_deep_nesting`). Write-up in `todo.md`.

Remaining typed JSON decode costs were profiled on the prepared local Linux
benchmark container. A bounded word-at-a-time string scanner showed no
instruction or timing win and was discarded; profile and measurements are in
`fix-gc.md` §2.8 and `JSON_DECODE_PERF_PRD.md`. No speculative parser change
is queued until another profile supports a candidate.

Redis driver hardening (2026-10-09): configurable per-reply byte and
aggregate-element limits, linear fragmented-reply accumulation, and FIFO
pool wakeups are implemented and measured locally; raw values are in
`todo.md`. The 8 MiB fragmented-reply probe improved about 29x, while 20,000
small PINGs showed no measurable change. The API-server Redis path still
needs a route-level measurement before making a production throughput claim.

## 1. User-defined generics, then zokor

- [x] **Why.** zokor, the backend framework (`dolphlabs/zokor`, empty), has to
  carry the application's own state through a router, middleware and handlers:
  `Router[S]`, `Ctx[S]`, `fn(Ctx[S]) -> Response`. slang had no generics,
  interfaces, closures or `any`, so a library could not name a type the app
  defines. `tyto`'s 12-parameter `dispatch` is the symptom, and `tyto` and
  `slang-lipo` already copy the same infrastructure between them (`dotenv.sl`
  is byte-identical). Decided: generics come first, all of structs, methods and
  functions, before any zokor code. (Done below; closures remain the one
  missing piece for inline handlers.)

  **Model.** Monomorphized, type parameters unbounded, bodies checked per
  instance (the C++ template model) with an "in instantiation of" note on
  errors. `Box[T]` bracket syntax, matching `opt[T]` and `chan[T]`. Type
  arguments are inferred, never written at a call site. Each instance is
  produced by re-parsing the generic's tokens, so an instance cannot inherit
  another's annotations and a new AST field cannot escape it.

  **Sequence**, one PR each, merged and verified on macOS and Linux before the
  next, none stacked:
  - [x] **0.** Stable table storage; one iterator over function bodies (#169).
    Generated C byte-identical for 115 programs.
  - [x] **1.** Generic structs: `struct Box[T]`, `Name[args]` in types,
    struct-literal inference, templates and instances, mangling (#173).
    Generated C byte-identical for all 116 programs; `Box[int]` generates the
    same C as a hand-written `IntBox`. Struct bodies are now emitted
    dependencies first, and a negative test can carry an
    `expected_error.txt`.
  - [x] **2.** Methods on generic structs (`impl Box[T]`), instantiated lazily.
    Landed with per-instance method bodies (re-parsed, enum rewrite
    re-run); covered by generics_methods* tests.
  - [x] **3.** Generic functions, with unification and expected-type inference.
    Landed with call-site inference (no type arguments written);
    covered by generics_func* tests. Refusals (`spawn`, bare value,
    `extern`, lifetimes) carry messages plus negative tests.
  - [x] **4.** Hardening: cross-package generics (generics_pkg,
    generics_func_pkg, generics_methods_pkg), error notes
    (instance_note tests), docs (README generics sections). Instance
    bloat warns past a threshold (default 64,
    `SLANG_INSTANCE_WARN` overrides) at the end of codegen.
  - [x] **5.** A mini `Router[S]` with `Ctx[S]` over an app-defined `S`, as the
    proof (tests/generics_router: generic structs + method + generic
    dispatch fn + plain handlers over one instance); then zokor.

  **Cost model** (measured on one Mac; treat as an order of magnitude): about
  97% of a build is `cc -O3 -flto`, every program carries a ~6,300-line
  runtime, and one representative 12-line function adds ~33 lines of C, ~1.1 KB
  and 25 to 38 ms. Instances multiply that by instances *used* times methods
  *used*; a typical app has one `S`.

  **zokor v0.1**, as agreed: config and dotenv, the error-code registry, the
  rate limiter, a router with `:params` and before/after middleware, the serve
  loop with graceful shutdown; WebSocket, **rewritten from RFC 6455** (not
  ported from `slang-lipo`); a `zokor check` layout checker; Postgres helpers
  and a testing kit. Needs `crypto.sha1` in slang first. The layer rules to
  enforce are already written down in `tyto`'s `AGENTS.md`: import direction,
  only the DB adapter imports `pg`, every package has tests, routes private by
  default, tenant id an explicit parameter.

## 2. Servers cannot be stopped by SIGINT or SIGTERM

- [ ] **Found by the 4-way HTTP benchmark (2026-09-29).** Importing `proc`
  for anything (the bench server only called `proc.getenv`) blocks SIGINT and
  SIGTERM in every thread and turns them into a flag,
  `proc.shutdown_requested()`, that the program has to poll. A program that
  never polls cannot be stopped by Ctrl-C or `kill` at all, only by
  SIGKILL. Worse, the shutdown hook makes a blocked `accept` return an
  error, and the usual `guard ... else { continue; }` accept loop retries it
  forever: measured, the bench server went to 98% of a core after SIGTERM
  and kept answering requests. So a server cannot do a rolling deploy
  unless its author knew to poll. zokor's
  `listen_and_serve` polls and does exit; a plain stdlib `http` server does
  not. Without `proc` the signals keep their default action and end the
  process.

  Needs a decision on the contract before code (the README's own description
  of the mechanism is also stale: it describes a handler on the main thread,
  and it is a dedicated `sigwait` thread now). The `todo.md` item
  "`bench/http`'s server does not exit on SIGTERM" is this.

## 3. zokor: dynamic routes and body decoding cost 2-4x plain slang

- [ ] Same benchmark: zokor matches a plain stdlib `http` server on its static
  route (~70k req/s), but `/users/:id` runs at half the plain server's rate
  (33.7k vs 66.7k) and `POST /echo` at a quarter (14.6k vs 56.0k), with
  more wrk timeouts at 50 connections. CPU per request: zokor 131us, plain
  slang 67us. The extra cost is in zokor's router param path, `Ctx`, and the
  `dto` decode path, not in slang's `http` or `json` (the plain server uses
  both). Tracked in detail in zokor's `todo.md`; recorded here because zokor
  is where slang's HTTP performance gets judged.

## 4. Tail latency under concurrent load

- [x] **Found and fixed (2026-09-29): run-queue starvation, not wakeup
  delay.** A load generator that records every request's latency (wrk's
  own tail was inflated: its reported average broke Little's law by 10x)
  put plain slang at 200 connections at p50 0.34 ms, p99 17 ms, but p99.9
  313 ms and a max of 4.7 s, with the slow requests concentrated on the
  same connections. Rebuilding with a single global FIFO removed the tail
  entirely (p99.9 6-12 ms, max 14-23 ms, no timeouts) at the same
  throughput, which named the stage: workers scanned the 16 stripes from a
  fixed "own" stripe, so the stripes no worker owned starved. A CPU-bound
  test showed it plainly: 43-50 of 64 tasks never ran at all in 1.5 s.
  Fix: each worker's scan starts one stripe further on every pop
  (`sl_runq_scan_start`). Result: p99 5.6-6.6 ms, p99.9 11-16 ms, max
  20-52 ms, zero timeouts, throughput unchanged. Go net/http on the same
  harness: p99 12.6 ms, p99.9 22 ms. The fast 0.3 ms median was a product
  of the unfairness (the owned stripes cycled quickly while others
  starved); fairly scheduled, the median is ~3 ms, the Little's-law mean
  at this throughput, so the median now moves with throughput (#5).
  Test: `tests/sched_fairness`.

  **Cost, measured:** plain slang throughput -2 to -3%. zokor under wrk at
  200 connections -14 to -20% on its dynamic routes (`/users/:id`
  44.7-52.0k -> 37.9-41.9k, `/echo` 37.4-40.1k -> 26.6-30.9k), because
  zokor's panic recovery (#20 there) spawns a child task per request and
  parks on it: the old scheduler kept that hand-off hot on one worker
  while starving half the connections (782 wrk timeouts); fairly
  scheduled, both hand-offs queue behind everyone. See #4b.

  The original measurement, kept for the record:
  **Measured 2026-09-29** (4-way bench, one laptop, wrk -t4, 3 rounds):
  plain slang's p50 beats Go's (0.3 ms vs 1.1-1.4 ms at 200 connections), but
  its p99 is 700-860 ms, with 25-155 requests per 10 s run hitting wrk's 2 s
  timeout; Go net/http's p99 is ~10 ms, Fiber's ~3 ms. The distribution is
  bimodal: most requests are fast, some stall for up to two seconds.

  **Not the GC.** Under the same load `SLANG_GC_STAT` showed a longest major
  pause of 1.8 ms and a longest minor of 5.1 ms. `SLANG_SCHED_STAT` showed one
  park and one resume per request and essentially no preemption. The stalls
  are between a connection's wakeup and its task running again.

  **First step:** measure, per resume, the time from the reactor seeing the
  fd ready to the task being dispatched, as a histogram, to split "the
  reactor delivers late" from "the run queue waits". Live hypotheses: the
  global doorbell (one broadcast per push), per-worker queue unfairness, and
  lost wakeups rescued by a later event. No algorithm change without a
  measurement that names the stage.

## 4b. Hand-off locality: a `runnext` slot

- [x] **Done (2026-09-29).** Per-worker `runnext` slots (`sl_runq_ready`,
  `sl_runnext`): a task woken (`sl_task_resume`) or spawned by a running
  task runs next on that worker; a runnext chain inherits the chain's
  start as its `run_start_ns`, and past a quantum the slot's task goes to
  the fair stripes instead; a displaced occupant goes to the stripes; an
  idle worker steals slots before sleeping (sequentially consistent
  sleeper count, so a put never strands a task); the slots are a GC root
  source. zokor at 200 connections under wrk, alternated against the
  fairness fix alone: `/users/:id` 40.1k -> 55.1k (1.37x), `/echo`
  29.1k -> 43.4k (1.49x) -- above even the pre-fairness numbers -- with
  zero timeouts and a better tail (latgen, `/users/:id` p99 12.3 -> 7.3
  ms). Plain slang, which hands nothing off, is unchanged within noise
  (-2% or less). Test: `tests/sched_runnext` (128 ping-pong pairs plus
  spinners; a runnext giving each hand-off a fresh slice fails it).

  The motivation, as recorded before:
  With the run queues fair (#4), a task woken or spawned by the running
  task waits its turn behind every other runnable task, on whichever
  worker gets to it. Go avoids that with `runnext`: the task the current
  one just readied runs next on the same worker (cache-hot), and inherits
  the rest of the time slice so a ping-ponging pair cannot starve anyone.
  Here it would keep request/response pipelines and spawn-then-join
  (zokor's per-request panic recovery) on one worker, and should win back
  the zokor throughput #4 cost and more. The slot must be one of the GC's
  root sources (like the stripes) and must not reintroduce starvation:
  measure with `bench/latgen` and `tests/sched_fairness`, not wrk alone.

## 5. Per-request allocation in stdlib `http`

- [x] **Done (2026-09-29).** A static `GET /` through a plain stdlib `http`
  server: 24 GC allocations and 1501 bytes per request -> 11 and 798.
  `/users/:id` 28 -> 15, `/echo` 36 -> 25. Every one of the 24 was
  attributed to its call site first (allocator instrumented with a
  frame-pointer walk, symbolized with atos). Where they went:
  - 7 were `result` wrappers and structs threaded through `read`'s private
    parse (Head, HeaderScan, Framing, each in a result, plus a re-wrap).
    The socket path now parses into one `WireHead` per attempt and
    returns errors as a str.
  - 4 were two `b""` literals: an empty `bytes` was two allocations every
    evaluation. The compiler now emits one shared static empty
    (`sl_bytes_empty`) -- language-wide.
  - 2 were the method and version strs: the common methods and both
    versions are literals now.
  - 1 was the `opt` inside `wants_close`, which now decides in place.

  wrk, alternated order, plain slang server against `dev`: `/` +12%
  (c=50) and +15% (c=200), `/users/:id` +18% and +12%; `/echo` at c=200
  +17% (71.2k vs 61.0k, ABBA order, 6 runs each). Zero timeouts.
  Pinned by the "allocation budgets" section of `tests/run_tests.sh`
  (`tests/http_read_wire`, `tests/bytes_empty_literal`).

  One trap found on the way, now in `read`'s comment: the first version
  allocated the WireHead before `recv`. On a kept-alive connection that
  object sat through the park, a minor GC promoted it, and every young
  str and bytes the parse then stored into it was promoted with it --
  25x the promotions and 3x the pause time under 200 connections of
  POSTs, and `/echo` 11% slower despite fewer allocations. Anything
  allocated before a park and written after it has this cost.

## 5b. What is left of the per-request cost is the language's

- [x] **One-object `bytes`, done (2026-10-01); value `result`/`opt`
  deferred.** Design note with measurements: `runtime/VALUE_REPRESENTATION.md`.
  Across seven workloads, `bytes` headers were 18–35% of allocations in
  network and file code, and `result`/`opt` 5–13%. A `bytes` is now one
  object (`sl_bytes_alloc`, every runtime constructor). The blocker, that
  conservative scanning sees only object starts, reduced to one fixed-offset
  check (`sl_gc_mark_inline_bytes`): parked tasks are rooted precisely, and
  only a word equal to `b->ptr` needed recognizing. `http.read` 7 -> 6
  allocations, and stdlib `http` `GET /` +4% and `POST /echo` +3% (ABBA,
  medians; the POST spread is wider than the delta). The 12 two-object
  sites also each had a header-then-data ordering window, which a single
  allocation removes.
- [ ] Value `result`/`opt`: deferred. The runtime builds them in ~220
  places across 11 files, and they reach most codegen passes, for 5–13% of
  allocations. Revisit after the young-object allocator work, with a
  measurement showing the count, not the cost per allocation, still
  matters.

## 6. x86_64 trampoline calls C with a possibly misaligned stack

- [x] **Done (2026-09-29).** The async-preemption trampoline (both x86_64
  copies, Darwin and Linux) now keeps the unaligned `%rsp` in `%rbx`,
  rounds `%rsp` down to 16 bytes for its three C calls, and addresses the
  save block's two slots through `%rbx`. Measured before the fix with a
  probe inside `sl_preempt_yield` (`sl_rt_call_misalign`, reported as
  `misaligned_preempts` by `SLANG_SCHED_STAT`): 17-21% of async
  preemptions called C misaligned (133-191 of 770-911 per run of
  `tests/sched_fairness` under a 1ms tick and quantum); after, 0. The
  suite now checks that count. arm64 needed nothing: its trampoline's
  816-byte block is a multiple of 16 and sp is kept aligned by the
  hardware. Task start (`sl_ctx_trampoline`) and stack growth
  (`sl_grower_trampoline`) were checked and were already aligned: both
  enter on the 16-aligned stack top `sl_ctx_make` builds.

## 7. Minor GCs trace every roots-reachable old object

- [x] **Done (2026-09-30).** A minor now traces no old object at all, and
  looks up pointers in a table of the young list only, where it used to
  trace every old object reachable from the roots and rebuild a table of
  the whole heap. Per-minor cost against a long-lived cache
  (`Entry` structs in a map and a list, 3M iterations making garbage):

  | cache | before | after |
  |---|---:|---:|
  | 20k entries | 5.6 ms/minor, 8.0 s run | 0.8 ms, 3.1 s |
  | 200k entries | 104 ms/minor, 111 s run | 1.4 ms, 5.4 s |
  | 1M entries | 350 ms/minor (roots fixed, table not yet), 501 s | 14 ms, 26.6 s |

  Steady state (the cache built, the loop running) is 0.8-0.9 ms per
  minor at every size; what remains at 1M is the build, see #7b.

  The full-mark root phase had been hiding five places where a young
  object became reachable only through an old one with no write
  barrier. A new verifier (`SLANG_GC_VERIFY_MINOR`: every minor checked
  against a full mark from the same roots) found them all:
  - struct literals allocated the struct before evaluating its fields,
    so a minor inside a field expression promoted it before its young
    fields were stored (codegen now allocates after the last field);
  - `select`'s send arm skipped the barrier `chan_send` has;
  - `recv` allocated its result's bytes header before parking and filled
    it after (it is now built once the data is in);
  - a finished task's remembered entries were dropped with it, and its
    shard buffer leaked (now handed to the next collection);
  - a major collection kept its young survivors young while discarding
    the remembered set that pointed at them (majors now promote what they
    keep).
  Each is reproduced by `tests/gc_minor_barriers` or `tests/gc_ctor_payload`
  under the verifier when reverted; the suite runs 14 GC-heavy tests under
  it and requires `missed=0`.

## 7b. Bulk-filling a very large container re-traced it on every minor

- [x] **Done (2026-09-30).** Lists and maps carry a frontier (`gc_clean`,
  in padding the structs already had, so no memory): a minor traces a
  remembered container only from the first position written since the
  previous minor. Appends, `a[i] = v`, new map keys and deletes lower it
  to the position; stores whose position is unknown reset it to 0, the
  old whole-container trace. A long-lived cache of 1M `Entry` structs in a
  map and a list:

  | | before | after |
  |---|---:|---:|
  | building it | 20.5 s, 29.8 ms/minor (max 102) | 3.4 s, 0.77 ms/minor (max 6) |
  | building + 3M iterations | 24.0 s, 17.3 s of minors | 7.9 s, 1.2 s of minors |

  Same footprint. Test: `tests/gc_container_frontier` (appends, pop then
  push, `a[i] = v` below the frontier, map inserts, updates and deletes),
  run under `SLANG_GC_VERIFY_MINOR`. Testing it found the map `del` bug
  (#252).

## 7e. Leaf-loop safepoints (design note, approved 2026-10-01; implements §5)

**Problem.** Every `while`/`for` iteration emits a full safepoint
enter/exit: a roots array, a `sl_safepoint`, `sl_rt_safepoint_enter` (TLS
read — a TLV call through dyld on Darwin), stack-growth probe, GC
check-in, preemption sample, and exit (another TLS read). Byte-scan loops
with no call and no allocation (`while b[i] != 44 { i = i + 1; }`) pay
all of it. Batch's parser runs ~30 such iterations per CSV row.

**Guarantees a safepoint provides, and what a leaf loop needs of each:**

- **GC stop-the-world.** `sl_gc_stw_sync` waits for every thread to ack or
  block; a thread spinning in a no-check-in loop still acks because the
  async-preemption path (SIGUSR1 → trampoline → queued with
  `async_preempted=1`) lands it at an ack point. Bound: ticker tick (2 ms
  default) + quantum (10 ms default). The collector then roots that task
  through its safepoint chain *plus* a conservative scan of the
  interrupted stack (queued/running-task scan), so a hoisted bracket plus
  the conservative fallback keep it sound. Must still be measured (STW
  latency under a spinning leaf loop), not assumed.
- **Rooting.** Roots arrays snapshot pointer values at enter. A leaf loop
  may reassign pointer variables (`p = p.next`); if the frame is hoisted
  out of the loop the snapshot goes stale and only the conservative scan
  of an async-preempted task would see the new value. So: hoist the
  bracket (roots stay linked and correct — the chain always points at the
  live frame), but do NOT drop the per-iteration check down to nothing
  for loops that reassign pointers. Leaf loops whose pointer variables
  are all loop-invariant may skip the per-iteration check entirely (async
  preemption covers STW + fairness); all other leaf loops get the cheap
  poll below.
- **Stack growth.** Only happens at safepoints; a leaf loop creates no new
  frames, so no growth check is needed inside it. (The hoisted enter
  still probes once.)
- **Preemption fairness.** A task in a long leaf loop must still yield.
  The poll below checks the same condition `sl_rt_maybe_yield` checks;
  async preemption covers the rest. Proven by `tests/sched_fairness` and
  `SLANG_SCHED_STAT=1` with forced preemption.

**Design (Option B, chosen): cheap poll per iteration, full safepoint
only when set.** Codegen detects a *leaf body*: no call (including
method calls, spawn, and anything that lowers to a call), no allocation
(list/map literals, struct literals, string concat, `none`/`ok`/`err`
wrappers that allocate), no park (channel ops, `select`, blocking net/io).
For a leaf `while`/`for` with live GC roots, emit the bracket hoisted
around the loop plus, per iteration, one relaxed load of the existing
GC-request flag (`sl_gc_stop_requested` / collect-pending, the same
condition `sl_rt_gc_checkin` tests) and the run-queue-nonempty preemption
gate: if either is set, take the full `sl_rt_safepoint_enter` path
(re-link + check-in + sampled yield); else continue with zero TLS reads.
Scalar leaf loops keep today's 1-in-1024 sampled `sl_rt_maybe_yield`
(already cheap). Fallback if the per-iteration load still shows in
profiles: counted poll every N iterations (Option C).

**Correctness rules:** the poll reads only atomics, never TLS (arm64
thread-pointer caching is unaffected); no allocation exists in a leaf
body so the no-safepoint-between-alloc-and-init rule is vacuous; the
hoisted bracket keeps every loop-carried root linked for the whole loop;
generated C stays warning-free under gcc and clang.

**Evidence required before merge:** single-threaded batch 5M rows ABBA
(medians + raw); `tests/sched_fairness` + the preemption-alignment
section of `make test`; a new test where a tight leaf loop in one task
must not stall another task's GC beyond a stated bound (fails if leaf
loops neither poll nor get preempted); full GC verifier matrix
(`SLANG_GC_VERIFY_MINOR=1 SLANG_GC_NURSERY_KB=16`, incl. forced async
preemption, `missed=0`); linux-arm64 CI dispatch.

## 7f. Cheaper young-object allocation (design note, approved 2026-10-01)

**Problem.** Every object is its own `malloc` with an `sl_gc_obj` header,
onto a per-task pending list, then into young/old linked lists, with a
small size-class freelist (`c40..c320`). Every collection rebuilds
`sl_gc_set`, a hash set of *every* object start. One 97 KB 2,000-item
decode: ~905 µs, ~4,000 allocations (the minimum: one struct + one string
per item); GC ~30%, per-object malloc most of the rest. Lower the cost
*per allocation* and *per minor*, not the count.

**Direction (phased so each PR verifies alone):**

- **Phase 1 — young pages + bump allocation: done (2026-10-02).**
  Per-worker 16KB pages (16KB-aligned, mask lookup, 1MB cap per
  worker): bump-allocate within a page, first-fit free lists refilled
  once per surviving page per sweep by a linear bitmap walk, slot
  extents in a header `cap` word the walk strides by. As designed,
  large objects still use malloc and the bitmap records starts for
  validation (Phase 2's input). One deviation from the note: variable
  bump, not fixed size classes — the decode path's strings never match
  an exact class (the old freelist hit 199 of 802,624 allocs), so
  classes would have left the workload on malloc. Found building it:
  absorbed split waste untracked by a size-striding walk files
  fragments the next claim overwrites a live header with (a
  deterministic segfault in `gc_map_put`); the cap word is the fix.
  Quote decode 200x2000: 153.8 ms -> 81.9 ms ABBA medians (1.88x),
  minor pauses 47.3 ms -> 14.9 ms, RSS 6.26 MB -> 3.34 MB, identical
  802,624 allocs (budgets untouched). Full suite green incl. verifier
  matrix; `SLANG_GC_PAGE_DEBUG` checker landed beside it.
- **Phase 2 — page-table validation.** A page table + bitmap lookup
  replaces building `sl_gc_set` on every minor (the per-minor O(heap)
  rebuild). Also makes interior-pointer lookup cheap, which the
  value-result/opt option in `VALUE_REPRESENTATION.md` would need.
- **Phase 3 — page sweep.** Free whole pages, or bitmap-clear on sweep,
  instead of walking linked lists.

**Non-negotiables:** non-moving (the conservative fallback cannot rewrite
pointers — not relitigated); every candidate-pointer check keeps working
(object starts + #277's inline-bytes rule); remembered set and
`gc_clean` frontier semantics unchanged; thread-locals through accessors,
preempt brackets around libc, no GC allocation under a mutex.

**Measure before/after each phase:** the json decode microbenchmark
(decode `quote_0.json` 200×; generate with `python3
bench/suite/lib/gen_quote.py <dir> 1 2000`); `POST /api/quote` vs Go
(p99 via `bench/latgen` + RSS); `tests/run_tests.sh` allocation budgets
(must not change); RSS on api + batch. Allocation count is pinned by the
budgets — the win must come from cost-per-allocation and minor cost.

## 7d. Updating existing map keys re-traces the whole map each minor

- [ ] A map update's position in the order array is not recorded, so it
  resets the map's frontier to 0: a 200k-entry map whose existing keys are
  rewritten with fresh values costs about 10 ms per minor (no worse than
  before #7b, but not the nursery's worth). One way: record the young
  value itself in the task's remembered set instead of the map (validated
  at the minor against the young table, promoted there), with a per-cycle
  cap that falls back to the whole map. Measure against a cache-refresh
  workload before choosing.

## 7c. macOS keeps freed heap pages that Linux gives back

- [ ] After a major, the collector calls `malloc_trim(0)` on glibc and
  nothing on macOS, so pages the sweep freed stay in the process's
  footprint until malloc reuses them. #7 made it visible: building a
  200k-entry cache peaks at a 77MB physical footprint against dev's 65MB,
  with the same peak RSS (89MB) and identical collector counts -- dev's
  per-minor full table happened to flush those pages. Measured with
  `malloc_zone_pressure_relief(NULL, 0)` after each major: RSS 89 ->
  72MB, footprint 77 -> 72MB at 200k and 13.6 -> 9.7MB at 20k (dev
  13.9), but each major about 12ms (21%) longer on that heap (worst 155
  -> 185ms). Decide the trade across workloads -- a small-heap server, a
  CLI, a large cache -- before choosing: always, never, or only after a
  major that freed a lot.

## 8. CI on `dev`, not only `main`

- [ ] `.github/workflows/ci.yml` runs on a push to `main` and on manual
  dispatch (releases moved to `release.yml`: a pushed `vX.Y.Z` tag is
  tested on every platform and published with its tarballs, see
  CONTRIBUTING, "Releasing"). **Nothing runs on a pull request to
  `dev` or a push to `dev`**, so a change reaches `dev` verified only by
  whoever opened it.

  `dev` → `main` merges do run it (green on 2026-09-29), so problems
  surface, but only after merging. That has been true of every PR since the
  last clear-out. Each of #157,
  #159–#162, #164 and #165 was checked by hand, on macOS and in an Ubuntu
  24.04 container, never on arm64 and never on GitHub's runners. The tree of
  `dev` at `f9680d1` did pass the full suite that way (243 on macOS and on
  Ubuntu); what has not run is the workflow itself, so the arm64 legs, the
  live Postgres job and the docs build have not seen any of this.

  The first time CI sees these changes will be the next `dev` → `main` merge,
  which is a late place to learn that arm64 disagrees.

  **First step, cheap:** dispatch the workflow on `dev`
  (`gh workflow run ci.yml --ref dev`) and read all three legs.

  **Then:** decide what should run on a PR. Linux x86_64 and macOS are the
  fast legs; the arm64 legs and the live Postgres job are slower, and the
  file's own constraint stands (nothing in it may reach the internet).

## 9. Remote benchmarks

- [ ] Run the cross-language suite on a Linux host and record it in
  `bench/RESULTS.md` as its own run.

  `bench/run_remote.sh` is built, with a preflight that inspects the host
  before anything runs. It needs a host chosen deliberately: the suite
  saturates every core for minutes and binds ports, so it must not run on
  a machine serving anything.

  **Waiting on a full run.** PR #150 holds interim results from a scaled-down
  run. The planned run (2026-10-01, `bench/CURSOR.md`): a Hetzner CCX33
  (8 dedicated vCPU, 32 GB) at full data scale, measuring slang, Go, Rust,
  Java and Node only, `ROUNDS=3` with 20 s api and 15 s http windows, about
  2h 15m. When it has run:
  - update `bench/RESULTS.md` and the website with the heavy-tier numbers;
  - the site shows the five measured languages, with the date and host;
    C#, Bun, Python and C keep only the claims earlier runs support;
  - the Java `api` heavy tier should now build (a `.gitignore` pattern had
    been hiding its `Main.java`); check that it does.

- [ ] **Found reviewing slang's suite programs (2026-09-30), before the full
  run.** Measured on the Intel laptop; the batch program was rewritten, the
  rest are runtime and compiler costs the programs cannot avoid:
  - `json.decode` of the 97 KB quote body takes 14.8 ms, ~26,000
    allocations and 2 MB allocated: it parses into a GC'd `sl_json_val` tree,
    then walks it, finding each field with a linear `strcmp`. `api/quote`
    served 41–81 req/s on 4 workers here (#150: 128–203 against Go's
    6–7k). Decoding straight into the target type is the fix, and the
    largest gap in the heavy tier.
  - [x] **Decode leftovers closed without code (2026-10-02).**
    `sl_jd_key` clean keys are already in-place (0 allocs); escaped
    keys cost exactly 1 alloc each, measured 4013 -> 8013 per 2000-item
    decode with all keys escaped, but real bodies never escape keys
    (and map keys must materialize anyway — they are stored). List
    growth is ~10 owned buffers per 2000-item decode, 0.25% of its
    4013 allocs, and no hint exists without pre-scanning the input.
    Neither moves the needle; the needle is Phase 2 (minors still
    ~15 ms of ~82 ms per 200 decodes, most of it the per-minor set
    rebuild).
  - [x] **Encode sizing, done (2026-10-02).** `json.encode` pre-sizes its
    builder from the static type's skeleton (field names and punctuation
    plus fixed-width scalar slots; `json_enc_hint` in
    `src/codegen/pkg_json/dispatch.c`, `sl_json_sb_reserve` in
    `runtime/sl_json.c`). A ~200-byte quote response went from 3
    allocations (64->128->256) to 1 and 20.2 ms to 11.5 ms per 20k
    encodes (ABBA medians; the request is still decode-bound at ~800 us,
    so this is not the api gap — the per-object allocator in §7f is).
  - Every `while` iteration emits a full `sl_rt_safepoint_enter`/`exit`
    (roots array and a TLS read), even a byte-scan loop with no call or
    allocation. Single-threaded, batch parses 5M rows in 5.8–6.8 s against
    Go's 2.0 s, with GC only ~0.45 s of that.
  - The collector scans `[int]` lists and int maps word by word as possible
    pointers (`sl_gc_trace_arr_range`, `sl_gc_trace_map_range`): a large int
    table costs a set lookup per word on every major.
  - `m[k] = v` on an existing key sets `gc_clean = 0`, so the next minor
    retraces the whole map. The old batch program did that per row and had
    not finished 20M rows after 11 minutes (Go: 3.3 s).
  - Go's batch truncates skus longer than 16 bytes (`skuKey`). The generated
    data has none; real data would be misreported.

## 10. Language gaps found and left alone

- [ ] **`spawn fns[i](x)` as an expression** (`let t = spawn fns[i](x);`) is a
  parse error: `spawn` in expression position takes only a named call. The
  statement form parses, and is the one the README documents.
- [ ] **A method that returns a reference cannot be called on a temporary or a
  field/element path** (`make().get()` where `get` returns `&int`). #164 refuses
  it with a message saying to bind the receiver to a variable first. Supporting
  it means the borrow checker tracking a loan against something with no name.
- [ ] **`arena`, `link` and `trip` methods only work on a variable**
  (`a.alloc(..)`, `conn.send(..)`, `t.pull()`). Their emission is keyed on a
  variable's name; on any other receiver #164 gives a clear error.
- [ ] **Raw mode and Ctrl-Z.** The process stops with the terminal still raw.
  Restoring on stop and re-applying on continue is what a full-screen program
  would need. `SIGKILL` and a crash cannot be handled at all, and are
  documented as such.
- [ ] **The frame guard's edges** (#171). A program that needs a guard is
  compiled twice, so its build time roughly doubles; none of the real programs
  measured needs one. `--emit-c` output has no guards, since it does not
  compile. Frames under 1536 bytes are still trusted to fit the 2 KB safepoint
  margin, which was not re-derived. The real cause of the growth on clang (one
  spill slot per call result, and callees inlined into their caller) is not
  something slang can change; only the guard contains it.
- [ ] **Terminal resize events and mouse input** for `io`. `term_width` /
  `term_height` are polled; there is no event, and a mouse report decodes to
  `"unknown"`.

## 11. Pass audit: leads with no failure found

- [ ] Closed as an audit (see `todo.md`, "Pass audit, first findings"). Left
  open, neither with a failure to show for it -- do not fix without one:
  - a local used only inside a callee that also contains a call taking a GC
    argument is protected today by the *outer* call's safepoint bracket; it
    was not proved that the entry checkin cannot collect it under several
    workers;
  - the runtime does not save or restore `errno` across a task switch, and
    about 64 reads of it sit between a syscall and the check of its result.

## 12. Command-line programs: what is still missing

- [ ] A line-editing helper built on `io.read_key`: cursor movement, history,
  a prompt that redraws. Not scoped. Candidate only; worth deciding whether
  it belongs in `stdlib` or in a program that wants it before writing it.

## 13. The cheapest language for an agent to build with

An agent's token bill is mostly not the code it writes. It is reading
(learning an unfamiliar language every session), retries (each failed
compile or test is another round), and tool output. slang cannot win on
training data, so it wins on those three. The zokor half (agent guide,
`zokor new`, `zokor gen resource`, OpenAPI) is in zokor's `todo.md`.

- [x] `llms-small.txt`: the language on one page, about 3k tokens, plus a
  package index generated from `api.json`'s data. Hand-written in
  `www/llms-small.md`; `tests/run_tests.sh` compiles and runs every example.
- [x] **Compiler errors built for agents.** `file.sl:12: error: ...` (the
  file was never named, and a package spans files), the first error of
  every function in one compile, "did you mean" for names, fields, methods
  and functions, and `--json`. Not done: columns (the AST carries lines
  only), and more than one error per function (a function's later errors
  are too often follow-on noise to be worth the risk).
- [x] **`slangc doc <pkg>[.<name>]`**: signatures and doc comments for the
  standard library, native, pinned and local packages, resolved as `import`
  resolves them. Reads source the way `www/build.py` does (fixed alongside:
  the site cut multi-line signatures at their first line and printed three
  native parameter kinds raw).
- [x] **One line when everything passes.** `slangc test` prints only
  failures and the count; `-v` brings back a line per passing test.
- [x] **Write the syntax rule down**: CONTRIBUTING, "If you change the
  language". The benchmark below measures retries per construct.
- [ ] **Measure it.** The harness is `bench/agent`: five tasks (CRUD, auth
  middleware, a background worker, rate limiting, uploads) as stack-neutral
  HTTP specs with hidden black-box acceptance tests, run in slang + zokor,
  Go + Fiber and TypeScript + NestJS, reporting tokens, turns and cost per
  run with medians. Its tests are checked against reference servers
  (`run.py selftest`). Not run yet: needs a budget, the agent and model to
  use, and zokor's own guide (`docs/llms-small.txt` in zokor). CRUD is
  in-memory, not Postgres, so the harness needs no database.
- Found while checking the guide's claims:
  - [x] **A `guard` whose `else` falls through compiles** -- now rejected,
    with the fix in the message. Functions that never return (`die(..)`
    helpers) are inferred, so ending an else with one still works, and
    `if let v = x { } else let e = err_of(x) { }` is the form for handling a
    failure and carrying on, which the guard had been misused for (about 30
    test sites and one in `stdlib/pg`).
  - [x] `let xs: [opt[int]] = [some(1), none];` failed with "cannot infer
    the type of 'none'": list elements did not take the annotation's type.
    List and map literals now give each element, key and value the type
    expected of it, wherever one is expected (a binding, an argument, a
    return, a field, an enclosing literal), and an empty `{}` takes its
    type from context as `[]` already did. Found with it: `[[], [1]]`
    against `[[int]]` was rejected, and a struct literal or call whose
    earlier field held `[some(7)]` was rejected when a later one made a
    call (the safepoint re-inferred the earlier value under the later
    field's type). Both fixed.
  - [ ] Open question: should an unannotated `[some(1), none]` infer
    `[opt[int]]` from its first element? It still needs an annotation,
    and `[none, some(1)]` would need one either way.
  - [x] A missing map key reported `(index 0, length 0)`; it now names the
    key and says to check with `has(m, k)` first.
- Found by the benchmark's first setup attempt (an agent following zokor's
  README exactly):
  - [x] A `slang.project` holding only zokor's `pkg` line failed with
    "missing name or version". The error now shows the lines to add, and
    zokor's README shows the whole file.
  - [x] zokor's guide used `import "../../src" as zokor;` in every block,
    which works only inside the zokor repo. The blocks now use
    `import "zokor";`, and zokor's snippet check maps that to the checkout.
  - [ ] `slangc get` passes through git's `refs/tags/v0.1.0 ... is not a
    commit!` for an annotated tag: harmless (the clone succeeds) but it
    reads like a failure.

## Notes

- Do not change `bench/http/main.sl` for perf experiments. Raw-best slang is `bench/http_opt/main.sl`; remasure with `./bench/run_http_opt.sh`. A recorded re-baseline under `fix-gc.md` Phase 8 is the one exception.
- No LLVM backend code without `fix-gc.md` 7.1's measurement.
- Phase E claim requires p99 **and** RSS vs Go; RPS alone is not a win.
