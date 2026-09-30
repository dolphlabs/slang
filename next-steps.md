# next steps

Work top to bottom, one item at a time; tick items as they land. Items 2
and 3 are being worked now.

Everything finished is cleared from this file to keep it short. The full
write-ups — why each design was chosen, what was measured, which controls
caught what — are in git history and the PR descriptions:

- before v0.2.0: `git show eeefce1:next-steps.md`
- Linux CI (x86_64 and arm64), OpenSSL discovery, `slangc test`, chunked
  request bodies, methods sharing a name with a package function, and the
  Postgres driver: `git show f9680d1:next-steps.md`

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

- [ ] Of the 11 allocations a `GET /` still makes, 5 are representation
  rather than work: every `bytes` is two objects (a `{len, ptr}` header
  and its data; the header block and `ok_text`'s body), and every
  `ok()`/`err()`/`some()`/`none` is a heap object (`read`'s result).
  Both are compiler/runtime changes that would cut allocations in all
  slang code, not just `http`:
  - `bytes` with its data inline in one allocation. Blocked on the
    collector: conservative scanning recognizes only object starts, so a
    stack holding just `b->ptr` (an interior pointer) would not keep `b`
    alive. Needs interior-pointer lookup in the conservative scan first.
  - `result`/`opt` as values instead of pointers: codegen, rooting of the
    pointer inside, storage in containers and generics.
  Decide which (if either) is worth it with a design note before code.

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

- [ ] `.github/workflows/ci.yml` runs on a push to `main`, on manual
  dispatch and on a published release. **Nothing runs on a pull request to
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
  run. When the full suite has run:
  - update `bench/RESULTS.md` and the website with the heavy-tier numbers;
  - the site shows only C#, Java, Go, Rust, Bun, Node and slang (Python and C
    are left out of it);
  - the Java `api` heavy tier should now build (a `.gitignore` pattern had
    been hiding its `Main.java`); check that it does.

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
- [ ] **Compiler errors built for agents.** Today slangc stops at the first
  error and names neither the file nor the column (`slang: error at line 2:
  ...`), so three mistakes cost three compile rounds. Report every error,
  with `file:line:col`, a fix hint where one is known, and `--json`.
- [ ] **`slangc doc <pkg>[.<name>]`**: signatures and doc comments from the
  real parser, for the standard library, pinned packages and local ones, so
  an agent asks for one API instead of reading a page or the source.
- [ ] **One line when everything passes.** `slangc test` prints a line per
  test; print `ok: N passed (time)` alone on success and detail only for
  failures (`-v` for the current output).
- [ ] **Write the syntax rule down** (CONTRIBUTING): no novel syntax without
  evidence. The benchmark below measures retries per construct.
- [ ] **Measure it.** Five tasks (CRUD on Postgres, auth middleware, a
  background worker, a rate-limited endpoint, uploads) in slang + zokor, Go +
  fiber and TypeScript + Nest; input and output tokens and turns until the
  tests pass, several runs each, medians reported. Before and after the items
  above, so each claim has a number.
- Found while checking the guide's claims:
  - [ ] **A `guard` whose `else` falls through compiles** (README: "the else
    branch must exit"). The bound name is then used uninitialized: `guard let
    v = o else { println("x"); } return v;` returns 0 for `none`, and for an
    `opt[str]` the program segfaults. Memory safety, so first.
  - [ ] `let xs: [opt[int]] = [some(1), none];` fails with "cannot infer the
    type of 'none'": list elements do not take the annotation's type.
  - [x] A missing map key reported `(index 0, length 0)`; it now names the
    key and says to check with `has(m, k)` first.

## Notes

- Do not change `bench/http/main.sl` for perf experiments. Raw-best slang is `bench/http_opt/main.sl`; remasure with `./bench/run_http_opt.sh`.
- Do not start LLVM.
- Phase E claim requires p99 **and** RSS vs Go; RPS alone is not a win.
