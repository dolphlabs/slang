# AGENTS.md — slang

Read this whole file before changing anything. It tells you what slang is,
how work is done here, what you must never do, and how to prove a change is
right. Where it says **must** or **never**, it is not a suggestion.

## 1. What slang is, and the bar

slang is a statically typed language for backend servers. It compiles to C
(`slangc` → `main.gen.c` → `cc -O3 -flto`), runs M:N green threads on a
worker pool, and has a precise, generational, stop-the-world collector. It is
built to be measured against **Go** (simplicity, concurrency, operability)
and **Rust** (speed, memory). It aims to beat Go and to be in Rust's league.

It is also meant to be **the cheapest language for an LLM agent to build
with**: few tokens to learn (`docs/llms-small.txt`), few retries (errors that
say the fix), and terse tool output. See `next-steps.md` §13.

The bar for every change:

- **Production quality.** Assume it ships to someone's servers tomorrow, under
  heavy load. No TODOs, stubs, placeholder logic, or "good enough for now".
- **No vulnerabilities.** Anything that parses client input is a security
  boundary (see `http`'s request-smuggling rules). Bounds-check, cap sizes,
  refuse to guess.
- **Small and fast.** Memory and latency are the product. A change that makes
  anything slower or bigger needs a measurement and a reason.
- **Claims need numbers.** Never say faster, smaller or fixed without a
  measurement or a failing-then-passing test to show for it.

## 2. Before you start

1. Read `CONTRIBUTING.md` (build, tests, workflow, runtime rules) and the
   README's *How it works* and *Memory management* sections.
2. Find your item in `next-steps.md` (the work queue, top to bottom). Runtime
   bugs and past investigations are in `todo.md`; search it before
   debugging anything in `runtime/`, since the answer is often already there.
   GC design: `runtime/GENERATIONAL_GC_HANDOFF.md`.
3. **Ask, don't assume**, when any of these is unclear: the scope, a language
   design choice (syntax, semantics, a new type or keyword), anything that
   changes a public API or the on-disk formats (`slang.project`,
   `slang.lock`), or a trade-off between speed, memory and simplicity. Pick
   the conventional default for everything else and say what you picked.

## 3. Repository map

| Path | What it is |
|---|---|
| `src/loader.c`, `lexer.c`, `parser.c`, `ast.h` | imports, tokens, AST |
| `src/codegen/` | type checking, passes and C emission: `infer.c`, `expr.c`, `stmt.c`, `program.c` (entry points, spawn trampolines), `liveness.c` (GC roots), `escape.c`, `move.c`, `borrow.c`, `generics.c`, `mir.c`, `native.c` + `pkg_<name>/` (native package signatures) |
| `src/main.c` | the driver: `cc` invocation, frame guards, `slangc new/get/test` |
| `runtime/` | C spliced into every program as ONE translation unit, in order: `sl_core` (tasks, preemption, thread-locals), `sl_gc`, `sl_containers`, …, `sl_sched` (context switch, trampolines, stacks), `sl_pool` (workers, run queues, signals) |
| `stdlib/` | slang-source packages (`http`, `pg`, `redis`, `httpc`, `http2`, …) |
| `tests/<name>/` | one package per test: `main.sl` + `expected.txt`; `fail_<name>/` must fail to compile; `tests/run_tests.sh` also runs the stress sections |
| `www/` → `docs/` | the docs site; `docs/` is generated **and tracked** |
| `bench/`, `stress_test/` | benchmarks and stress programs, with their own READMEs |
| `next-steps.md`, `todo.md` | the queue, and the investigations log |

## 4. Workflow (every task)

- **One branch per task, from an up-to-date `dev`.** Name it
  `fix/…`, `perf/…`, `feat/…` or `docs/…`. Open the PR with
  `gh pr create --base dev`.
- **Never stack PRs.** Before branching for the next task, check that the
  previous PR is merged by its state value (`gh pr view N --json state` →
  `MERGED`), not by a command's exit code. If it is not merged, branch from
  `dev` anyway when the work is independent, or ask.
- **Run one `make test` at a time.** Concurrent runs share `main.gen.c` and
  produce failures that are not real. For a stress program or benchmark
  build, use a separate directory (`slangc` compiles every `.sl` in a
  directory).
- **Commits:** conventional commits (`fix(gc): …`, `perf(http): …`), subject
  ≤72 characters, imperative, with a body saying what and why. When `docs/`
  changes, commit it separately as `docs: rebuild site for <topic>`. Never
  commit unrelated working-tree changes: stage files by name, not `git add -A`.
- **End every task with a `## Git` section:** commit messages, PR title, and
  a PR description in the What changed / Why / Notes for reviewer format.
  Write the description for someone who has not seen the conversation,
  including what failed before and what passes now.
- **CI** runs on merges to `main` and on manual dispatch
  (`gh workflow run ci.yml --ref <branch>`). Dispatch it for any change to
  `runtime/`, codegen of stores/spawn/switches, or anything platform-specific:
  it is the only native linux-arm64 run available.

## 5. Definition of done

A task is done only when **all** of these hold:

- [ ] **A test that failed on the old code and passes on the new one.** Show
      it: run the test against the old build and report what it printed. A
      test that passes on broken code is not a test.
- [ ] `make test` passes, generated-C warning sweep included, with the count
      reported.
- [ ] Memory-safety or GC-touching changes: the test is added to the GC
      stress lists in `tests/run_tests.sh` and passes under
      `SLANG_GC_VERIFY_MINOR=1 SLANG_GC_NURSERY_KB=16` with 0 missed.
- [ ] Performance changes: measured before and after (see §7).
- [ ] Docs: README, `www/llms-small.md` or the package docs are updated when
      behaviour or an API changes, then `make docs` has been run and `docs/`
      committed. If `docs/` conflicts between branches, regenerate it; never
      merge it by hand.
- [ ] `next-steps.md` / `todo.md` are updated: tick what landed, record what
      you found and did not fix.

## 6. Hard constraints

### Runtime and green threads (`runtime/`)

Tasks move between OS threads at any park, yield or async preemption. Most
bugs here are rare, platform-specific, and look like unrelated corruption.

- **Thread-locals from task code go through accessors, never bare.** Read
  `sl_rt_current_task` with `SL_RT_TLS_CUR()` inside a preempt bracket, or
  `sl_rt_cur()` outside one. Reach every other `_Thread_local` through its
  `SL_RT_TLS_ADDR_FN` accessor, inside a bracket. GCC on aarch64 caches the
  thread pointer for a whole function, and clang on Darwin caches TLV
  addresses, so a bare read after a switch uses the wrong worker's state. A
  bracket alone does not fix that. Bare reads are for native-stack code only:
  the worker loop, `sl_worker_after_switch`, thread registration, signal
  handlers.
- **Bracket every libc call that can allocate or lock** (`malloc`, `free`,
  stdio, `getaddrinfo`, OpenSSL) with `sl_rt_preempt_disable()` /
  `sl_rt_preempt_enable()`. Mid-call preemption abandons an allocator lock
  on another thread.
- **Never make a task discoverable before its context is saved.** Parking
  keeps the wait-list mutex held across the switch; `sl_worker_after_switch`
  releases it. Follow `sl_task_park` exactly.
- **Never allocate GC memory while holding a mutex**, and never allocate
  before a park only to fill it after.
- **Task stacks start at 8 KB** and grow only at slang safepoints: no large
  stack arrays and no deep recursion in C.
- **File order matters.** The runtime is one translation unit: declare
  before use, and keep the existing order.

### Collector and codegen

- **Every store of a GC pointer into a heap object needs the write barrier.**
  Minors trace no old object, so a missing barrier frees live data.
  `SLANG_GC_VERIFY_MINOR=1` is the check; run it for any change to
  barriers, promotion, codegen stores or a runtime container.
- **No safepoint between an allocation and the unbarriered stores that
  initialize it.**
- **Generated C must compile warning-free** under both gcc and clang.
- **Allocation budgets are enforced** (`tests/run_tests.sh`, allocation
  budgets section). Do not raise one to make a test pass; find the
  allocation.

### Language design

- **Familiar syntax only.** slang reads like Go and Swift (`fn`, `guard let`,
  `chan`, `??`) because models and people already know those. Never add novel
  syntax without evidence that the familiar form cannot work, and ask first.
- **No closures, no exceptions, no null, no interfaces, no reflection.**
  These are deliberate. Do not add them or emulate them. Work within
  function values, `opt` / `result` / `fault`, and generics.
- **Errors must say the fix.** A new diagnostic names the construct, the
  location, and what to write instead (see the empty-list and `none`
  messages). A compiler error must never surface as raw C compiler output.

### Performance and benchmarks

- **Never edit `bench/http/main.sl` for an experiment.** The raw-best
  variant is `bench/http_opt/main.sl` (`./bench/run_http_opt.sh`). The
  one allowed edit is a recorded re-baseline under `fix-gc.md` Phase 8:
  old and new ruler measured on the same host in one session, both kept.
- **No LLVM backend code without `fix-gc.md` 7.1's measurement.** The
  case for one is precise stack maps, not faster code; it is built only
  if that measurement shows the safepoint and rooting cost is worth a
  second backend.
- **A server-performance claim needs p99 and RSS against Go**, not RPS alone.
  Use `bench/latgen` for tail latency; `wrk`'s tail is unreliable here.

### Security

- Treat every byte from a socket, file, environment variable or command line
  as hostile: cap lengths, check bounds, reject ambiguity rather than guess.
- Never log secrets. Never shell out with interpolated input.
- Report a vulnerability as described in `SECURITY.md`, not in a public
  issue or PR.

## 7. Verifying: the tools

| Need | How |
|---|---|
| Missing barrier / unrooted value | `SLANG_GC_VERIFY_MINOR=1 SLANG_GC_NURSERY_KB=16 ./prog`, `SLANG_GC_THRESHOLD_KB=16` |
| GC and allocation counts | `SLANG_GC_STAT=1`, `SLANG_GC_CLASS_STAT=1` |
| Scheduler and preemption | `SLANG_SCHED_STAT=1`; force async preemption with `SLANG_PREEMPT_QUANTUM_MS=1 SLANG_PREEMPT_TICK_MS=1`; `SLANG_WORKERS=N` |
| Frame guards | `SLANG_FRAME_LIMIT=64` puts a guard on nearly every function |
| linux-arm64 (the host is Intel) | `docker run --platform linux/arm64 ubuntu:24.04`, `apt install build-essential pkg-config libssl-dev libsqlite3-dev zlib1g-dev`, build there. Same GCC as CI. Emulated timing amplifies races: good for reproducing, not for benchmarking |
| What the C compiler really did | `slangc x.sl --keep-c` plus `objdump -d`; argue from the disassembly, not from the source |
| A/B performance | ABBA order (old, new, new, old) over several rounds, medians with raw values; a delta smaller than the spread is noise. This laptop throttles |

Report outcomes as they are: if a test fails, say so with the output. If you
skipped a step, say which and why.

## 8. Communicating

- **Flag, don't silently fix.** A bug you find outside your task goes in the
  PR notes and `next-steps.md` / `todo.md`, unless it blocks the task. A
  memory-safety bug is raised immediately.
- **Match the surrounding code:** naming, comment density, idiom. Comments
  explain *why*; the code says what. When you introduce a new pattern, say so
  and why in the PR.
- **Never delete files, force-push, or rewrite shared history** unless
  asked.
