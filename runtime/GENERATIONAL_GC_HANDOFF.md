# Handoff: generational (young/old, non-moving, STW nursery) GC

Written for: whoever picks this up next (human or agent) — this session
is ending on a credit limit, not because the work is done. Everything
below is what the next person needs to start without re-deriving it.

## The problem, with numbers

`bench/run_http_realserver.sh` (merged, slang#196) measures slang's
`stdlib/http` server against Go's `net/http`, both keep-alive, both
doing real HTTP/1.1 parsing. Native run, 8 acceptors, 3 rounds:

| conc | slang req/s | p50 | p99 | Go req/s | p50 | p99 |
|---|---:|---:|---:|---:|---:|---:|
| 50  | 40,929 | 0.26ms | **29.6ms** | 60,154 | 0.56ms | 4.7ms |
| 200 | 40,367 | 0.31ms | **87.7ms** | 59,436 | 2.39ms | 16.7ms |

slang's *median* latency beats Go's. Its p99 is 6–9x worse, and req/s
is behind. Root-caused (not guessed) via `SLANG_GC_STAT=1` against a
purpose-built clean-exit diagnostic harness (a copy of
`bench/http/realserver/main.sl` with `proc.shutdown_requested()`-based
shutdown added, so the process exits cleanly and its
`__attribute__((destructor))` stat dump actually fires — the shipped
`bench/http/realserver/main.sl` does NOT have this, it's an infinite
accept loop, add it back if you need this again):

At the default 8MB threshold, c=200, 5s: **29 stop-the-world
collections, each pausing 13–51ms** — directly explains the observed
p99. At a 64MB threshold: only 6 collections, but pauses grew to **up
to 323ms each** — proves this isn't a "raise the threshold" problem;
pause cost scales with heap size, so bigger threshold trades frequency
for severity, not a fix.

The smoking gun in that same GC_STAT output: `marked=935` (tiny live
set) vs `swept=3,327,820`. **Every collection walks the entire object
population — millions of short-lived per-request strings and byte
buffers — even though almost none of it is live.** That's the sweep
cost, and it's the whole pause. This is exactly the case generational
GC exists for: most objects die young, so only scanning/sweeping the
recently-allocated region should be a small, bounded, frequent
operation, with full-heap collection rare.

## Why generational, not Go's concurrent tri-color (already decided —
## don't re-litigate this with the user unless they raise it)

The user's original question was "why not just build what Go has."
Answer already given and accepted: **concurrent** (Go's actual
pause-shrinking trick) and **generational** are orthogonal axes, and
only one matches the measured symptom.

- Concurrent marking moves work off the STW path via write barriers on
  *every* pointer store, background GC threads, and GC-assist logic —
  it reduces *pause* time but not total work, and Go's collector is
  explicitly **non-generational**, which is the *wrong* half to copy:
  it's why Go re-scans long-lived objects it doesn't need to, and is
  the more-criticized part of Go's own GC design.
- Generational collection directly shrinks the *amount of work per
  pause* (only sweep the young generation, not all 3.3M objects),
  which is exactly our measured bottleneck, and can stay fully
  stop-the-world (fine, because a minor collection is short by
  construction) — no extra heap headroom needed to keep a concurrent
  marker from falling behind mutators.
- Memory footprint risk: `sl_gc_collect`'s own comment already says it
  paces the threshold to the live set (`sl_gc_threshold = live_bytes`,
  floor 8MB — literally Go's GOGC=100 formula) and that ONLY works
  because mutators are fully stopped during collection. A concurrent
  collector needs *more* headroom on top of that by construction (Go's
  own 2x-live default exists for this reason), which is a real,
  structural threat to slang's current RSS lead over Go (see
  `bench/RESULTS.md`'s `http-static`/`compute` tables — slang is
  currently in the same single-digit-MB band as Rust and C, while Go
  sits higher). A non-moving generational nursery doesn't have this
  problem.

**Decision: young-generation nursery collector, non-moving (objects
never change address — see "why non-moving" below), stop-the-world for
both minor and major collections.** Concurrency is a legitimate later
step if pauses are still too long after this, but don't start there.

## Design

### Why non-moving (not a copying/semispace nursery)

The obvious textbook nursery design (Go's own old pre-1.0 approach,
many Scheme/ML runtimes) copies live nursery survivors into a compact
region, which requires rewriting every pointer that referenced them —
fine for a *precise* collector, but `sl_gc_collect` already has a
documented conservative fallback for async-preempted tasks
(`sl_gc_scan_conservative`, `sl_gc.c` ~line 712): a signal can land
mid-instruction with a live GC pointer sitting only in a spilled
register, scanned as a raw candidate word validated against `sl_gc_set`
before ever being trusted. **You cannot safely rewrite a conservative
candidate — it might not be a real pointer at all.** A moving GC needs
every root precise, which directly conflicts with a safety mechanism
this codebase added to fix a real, reproduced bug (see that function's
own comment for the crash it fixes). Don't relitigate this: non-moving
is the correct choice given what's already here, not just the simpler
one. It also happens to match what the user liked about Go's design
(Go's own collector is non-moving/non-compacting too).

### Data structures (`runtime/sl_gc.c`)

- `sl_gc_obj` gains a generation marker (e.g. `unsigned char gen;
  // 0 = young, 1 = old`) and a `remembered` dedup flag (`unsigned
  char remembered;`) — cheap, this struct is already the per-object
  header every allocation pays for.
- Split `sl_gc_all` into `sl_gc_young` and `sl_gc_old` linked lists.
  All new allocations (`sl_gc_alloc_fin`) land on young (via the
  existing per-task `gc_pend_*` shard — unchanged, still harvested the
  same way, just harvest onto `sl_gc_young` instead of `sl_gc_all`).
- A remembered set: per-task shard mirroring the existing
  `gc_pend_head`/`gc_pend_tail` pending-allocation design (same
  lock-free retire-then-harvest pattern, same reason: don't take
  `sl_gc_mu` on every mutator write). Holds pointers to **old**
  objects that have been written to since the last minor collection.
  Harvested into a global remembered-set array at the start of each
  minor GC, the same way `sl_gc_harvest_task`/`sl_gc_for_pending_tasks`
  already harvest pending allocations.
- New env var `SLANG_GC_NURSERY_KB` (mirrors `SLANG_GC_THRESHOLD_KB`'s
  existing parse-once-at-first-thread-registration pattern), default
  something in the few-hundred-KB to low-single-digit-MB range —
  needs tuning against the real-server benchmark, not guessed.
  `sl_gc_publish_bytes` needs a second threshold check against nursery
  bytes (minor GC) separate from the existing 8MB+ check (major GC).

### Minor collection algorithm

1. STW-synchronize exactly like today's `sl_gc_collect` (reuse
   `sl_gc_ack_and_wait`/`sl_rt_gc_checkin` machinery unchanged — the
   safepoint/quiescence protocol isn't generation-aware and doesn't
   need to be).
2. Harvest: every task's pending allocations → `sl_gc_young`; every
   task's pending remembered-set entries → a scan list.
3. Build `sl_gc_set` — **must include both `sl_gc_young` AND
   `sl_gc_old`** (mark still needs to validate any candidate pointer,
   precise or conservative, against the whole live population; a
   minor collection not knowing about old objects would treat every
   valid old pointer as "not one of mine" and silently corrupt
   conservative scanning at minimum).
4. Mark, starting from: (a) the same root set `sl_gc_collect` already
   walks in full (per-thread safepoint chains, run queue, run-queue
   stripes, parked tasks, async-preempted conservative stack ranges —
   copy this section verbatim, it's already correct and hard-won, see
   all the "Tier 11" comments explaining each root source's own bug
   history) — **and (b) every object in the remembered set from
   step 2**, tracing their fields via the existing `h->trace`
   callback exactly like a root.
5. **Critical invariant**: when `sl_gc_mark` reaches an **old**
   object, do NOT recurse into its children and do not add it to the
   sweep-eligible set — old objects are implicitly alive during a
   minor cycle (a full/major collection is what reclaims old garbage).
   When it reaches a **young** object, mark and recurse as today.
   This means `sl_gc_mark` needs to know an object's generation before
   deciding whether to push it onto the worklist for tracing — cheap,
   it's already dereferencing the header.
6. Sweep — **only `sl_gc_young`**, exactly like today's sweep loop but
   over the smaller list. Unmarked young objects are freed (existing
   `fini`/class-freelist path, unchanged). Marked young objects
   **promote**: unlink from `sl_gc_young`, relink onto `sl_gc_old`,
   set `gen = 1`, clear `marked` and `remembered`.
7. Clear every promoted-from-remembered-set old object's `remembered`
   flag (they were re-scanned this cycle; start fresh for the next).
8. Do NOT touch `sl_gc_old` beyond the relinks in step 6 — that's what
   makes this fast. `sl_gc_threshold`-based major-GC pacing (today's
   whole logic, `sl_gc_collect`) still exists, runs occasionally,
   sweeps `sl_gc_old` too, and is where old garbage actually gets
   reclaimed.

### Why this is correctness-safe re: "old object gains a pointer to a
### still-young object without going through the barrier"

It can't, given two things this design must guarantee together:
- **Promotion promotes the whole transitively-reachable-from-roots-
  and-remembered-set subgraph in the same cycle it's discovered** —
  step 4's recursion through young objects already does this
  naturally; a young object only reachable via another young object
  that survives gets marked (and therefore promoted) in the same pass.
  So at the *end* of any minor GC, no live old object points at a
  since-swept young object, and no live old object points at a
  still-young object that ISN'T also getting promoted this same cycle
  — the two survive or don't together.
- **Every subsequent mutation of an old object's pointer field goes
  through the write barrier** (next section), which is what catches
  the only other way an old→young edge can appear: a fresh write
  *after* promotion.

### Write barrier

**This is the risky, invasive part — the only part touching codegen,
not just the runtime.** Needed at every store of a GC pointer into an
already-allocated (potentially old) container: struct field
assignment, list/array element assignment, map value assignment,
anything else `emit_struct_tracers` would trace (that function, in
`src/codegen/program.c:433`, `mark((void *)o->field)` for every
GC-pointer field — is the authoritative enumeration of what needs a
barrier per struct type; instrument the same field set, don't
independently re-derive it).

**Recommended v1: coarse, unconditional barrier, not a precise
old→young check.** At every instrumented store site, if the container
object is in the old generation, unconditionally add it to the
per-task remembered-set shard (deduped via the `remembered` flag —
check-then-set, skip the call entirely if already set, so a hot object
written to repeatedly only costs one shard append per cycle). Do NOT
try to check "is the stored value actually a young pointer" in v1 —
that needs reading the value's own header (an extra memory access on
every barrier call, and the value might be a string literal or `.text`
address, needing the same `sl_gc_set_contains`-style validation
`sl_gc_mark` already does) for a savings that only matters once the
coarse version is proven correct and its remembered-set overhead is
actually measured as a problem. Simpler, safer, ship this first.

Known concrete codegen sites to instrument (found this session, not
exhaustive — a full audit of `src/codegen/stmt.c` and `expr.c` for
every GC-pointer store is the actual first task):
- `src/codegen/stmt.c:278` — struct field assignment (`p.x = v`),
  `emit_line(cg, "%s%s%s = %s;", ...)`. Guard: only when
  `type_is_gc_ptr(cg, sd->ftypes[fi])` is true AND the base struct
  `sd` is itself `gc` (a barrier on a non-gc/value struct's field is
  meaningless — nothing traces it).
- `src/codegen/expr.c:1455` and `src/codegen/stmt.c:479` —
  `sl_map_put(...)` call sites (map assignment). A barrier here is
  naturally placed *inside* `sl_map_put`'s own C implementation
  (wherever that lives in `runtime/sl_containers.c` or similar) rather
  than at every codegen call site, if `sl_map_put` already knows the
  map object's own GC header — cheaper to add in one place than at
  every generated call. Check whether the map's backing storage is
  itself a `sl_gc_obj` (it should be, maps are gc-traced) before
  assuming this shortcut works.
- **A second struct-field-assignment site**, distinct from the one
  above: `src/codegen/stmt.c:366` (`EX_FIELD` target, `p.x = v` where
  `p` is itself an expression, not a bare identifier the parser folded
  into a dotted name — `stmt.c:278` only handles the latter). Same
  emitted shape (`"%s%s%s = %s;"`), same guard condition, needs the
  same barrier call. Two sites doing the same job for two different
  parse shapes of "the same" assignment — don't instrument only one.
- List/array element assignment (`a[i] = v`) and map assignment both
  reachable from `ST_ASSIGN`'s index-target branch, `stmt.c:370`
  onward (right after the `EX_FIELD` case above) — not fully traced
  this session, follow it from there; `sl_map_put` call sites already
  found are `expr.c:1455` and `stmt.c:479`.
- Closures/captured variables, if slang closures capture by reference
  into a heap-allocated environment struct — check whether that
  environment struct already goes through `emit_struct_tracers`'s
  path (if so, already covered by the struct-field case above) or
  needs its own site.

### Resolved: interior `&mut` references (`*p = v` through a field/
### index reference) need the barrier at reference CREATION, not at
### the deref-assignment

This came up as an open question in a later planning pass and is worth
settling explicitly rather than leaving as "lean unconditional," which
is incomplete as stated. Checked directly against codegen:

`&mut`/`&` is fully generic (`expr.c:1717-1718`): `&mut expr` compiles
to `(&(<expr>))` for *any* `expr`, including `EX_FIELD` (`&mut
obj.field`) and `EX_INDEX` (`&mut arr[i]`) — nothing stops an interior
mutable reference into the middle of a GC struct or array. The
deref-assignment codegen (`stmt.c:306-336`, the `*p = v` case) permits
this for `TW_REFMUT` (`&mut`) and raw-pointer wraps, rejecting only
`TW_REF` (shared `&`, correctly — can't mutate through it at all).

**The problem with barrier-at-deref**: at `stmt.c:335`
(`emit_line(cg, "*(%s) = %s;", p, val)`), `p` is a bare interior
pointer — it does not point at the start of an allocation, so
`(sl_gc_obj *)p - 1` does not reach a valid header. There is nothing
correct to pass to a barrier call at that site. "Emit it
unconditionally" doesn't fix this; it just calls a function with no
way to identify what to remember.

**The fix**: trigger the barrier when the interior reference is
*created*, not when it's dereferenced. At the `&mut` codegen site
(`expr.c:1717-1718`), when the operand is `EX_FIELD` or `EX_INDEX`,
the compiler still has the CONTAINER's own pointer available right
there (see how `EX_FIELD`'s own codegen at `expr.c:1743-1748` computes
`b` — the base struct pointer — before erasing anything) — before it
gets folded into `&(o->field)`. Emit the remember-call there,
unconditionally, on the container, the moment a mutable interior
reference into it is taken — regardless of whether the reference ends
up actually written through. This is the same coarse-over-remember
philosophy already chosen for the direct-assignment barrier above,
just applied at the point where enough information still exists to
act on it. A plain `&mut x` where `x` is a whole local (not a field or
index) needs nothing — it's not an interior pointer into a GC
container in the first place.

Raw pointers (`unsafe` block required per `stmt.c:317-320`) are a
separate, lower-priority case: if a raw pointer is ever manufactured
FROM a GC object via an unsafe cast (not confirmed either way this
session — check whether the language allows this at all) the same
base-recovery problem applies, with no equivalent "creation site" to
hook since raw pointer arithmetic is exactly what `unsafe` exists to
allow. Worth a documented decision before shipping (e.g. "unsafe code
must not write GC pointers through a raw pointer into old-generation
memory" as a stated invariant, unenforced), but not a blocker for the
mainstream `&mut` case above, which covers the actual borrow-checked
language.

The barrier call itself (`sl_gc_remember(void *old_obj)` or similar,
in `sl_gc.c`) must follow the **exact same preempt-disable bracketing
discipline** `sl_gc_alloc_fin` already uses (`sl_rt_preempt_disable()`
/ `sl_rt_preempt_enable()` around the mutation) — see
`darwin-tlv-async-preempt-hazard` and `green-thread-c-library-hazards`
in this project's persistent memory (`/Users/utee/.claude/projects/
-Users-utee-Documents-slang/memory/`) for why: a bare
`sl_rt_current_task` read outside that bracket is unsafe on Darwin,
and any malloc/free the shard-append might trigger (growing the
per-task remembered-set array) needs the same bracket or it can abort
under real load.

## Sequencing (mirrors what worked for the http allocation work —
## branch per phase, PR to dev, Docker-verify every phase)

1. **Data structures + minor GC + promotion**, write barrier included
   from the start (there is no safe intermediate state without it —
   an old→young pointer written without a barrier is silent heap
   corruption on the very next minor GC, not a perf bug; don't ship
   any version without the barrier, not even behind a flag, beyond a
   local scratch build used only to validate root-scanning/promotion
   mechanics in isolation).
2. **Correctness tests first, before any benchmark.** New tests
   needed: (a) an object survives 2+ minor GCs (promotion happens,
   nothing frees it prematurely); (b) mutate an *old* object's field
   to point at a *freshly allocated* object via ordinary `p.x = v`,
   force a minor GC, assert the new object survived — this is THE test
   that catches a missing or buggy write barrier, the exact failure
   mode this design risks; (c) the same as (b) but through an interior
   `&mut` reference (`let r = &mut old_obj.field; *r = new_obj;`) —
   the direct-assignment barrier and the reference-creation barrier
   (see "Resolved: interior `&mut` references" above) are two
   different code paths and a test only exercising (b) would not catch
   a bug in the reference-creation one. Also: run the existing stress
   harness's pattern
   (`SLANG_GC_THRESHOLD_KB=16` in `tests/run_tests.sh`) with an
   equivalent low `SLANG_GC_NURSERY_KB` so minor collections happen on
   nearly every allocation during the whole existing test suite — that
   low-threshold stress mode is specifically what catches a rooting
   bug in this codebase's history (see the constant's own comment in
   `sl_gc.c`), and a generational rewrite needs the same discipline.
3. **Benchmark second**, only once correctness is solid:
   `bench/run_http_realserver.sh` (already built, this session) is
   the acceptance test — `pause_ns_max` should drop from the 13–323ms
   range measured above to something far smaller for minor GCs, with
   rare major-GC spikes. Also check RSS via the same script's
   `rss_kb` column and against `bench/RESULTS.md`'s existing
   `http-static`/`compute` numbers — the whole point of choosing this
   design over Go's was not regressing memory, so confirm it actually
   didn't.
4. Full `make test` + Ubuntu 24.04 Docker verification against `dev`'s
   own baseline (established pattern this whole session — same ~8
   pre-existing environment-gap failures expected, zero new ones) +
   an ASan pass (per `asan-needs-bigger-task-stacks` memory: raise the
   green-thread stack size before trusting any ASan finding, the
   default 8KB fails every slang program under ASan regardless of
   this change).
5. Branch per phase, `gh pr create --base dev`, verify merge by the
   PR's actual `state`/`merged` field value, not command exit code —
   per this project's standing workflow rules (persistent memory:
   `branch-per-task-pr-to-dev`, `check-merge-state-before-pushing`).
   Do not stack PRs silently.

## What's already true and doesn't need re-deriving

- The existing collector is precise except one documented conservative
  fallback (async-preempted task stack scan) — read `sl_gc_collect`
  and the comments immediately around `sl_gc_scan_conservative` in
  full before changing anything; they explain real, previously-
  reproduced bugs (rooting gaps for queued/parked/resumed tasks,
  entry_arg rooting, the async-preempt register-spill gap) that a
  generational rewrite must not reintroduce. The root-scanning code
  itself (walking threads/runq/stripes/parked) does not need to
  change for minor GC beyond what's noted above — reuse it verbatim.
- `bench/http/realserver/main.sl` and `bench/run_http_realserver.sh`
  (slang#196, merged) are the benchmark harness to validate this
  against. It's an infinite accept loop with no clean shutdown, so
  `SLANG_GC_STAT` won't print from it directly — either add
  `proc.shutdown_requested()`-based shutdown (see `examples/httpd/
  main.sl` for the pattern) to a throwaway copy for diagnostics, or
  extend the shipped one if a clean-exit mode is generally useful.
- `bench/scratch_alloc`-style harnesses (a loopback client+server in
  one process, N requests then clean exit) are the pattern used
  earlier this session for exact allocation-count deltas via
  `SLANG_GC_STAT`/`(allocs at N=2000 − allocs at N=1000) / 1000` — not
  committed to the repo (built ad hoc in `/tmp` and deleted after use
  each time), recreate similarly if needed for finer-grained
  measurement than the full HTTP benchmark gives.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
