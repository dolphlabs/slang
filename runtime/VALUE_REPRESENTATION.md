# Value representation: one-object `bytes`, value `result`/`opt`

The design note `next-steps.md` §5b asks for before any code. Two ways the
language's representation costs allocations: every `bytes` is two heap
objects (a `{len, ptr}` header and its data), and every `ok()`, `err()`,
`some()` or `none` whose payload holds a GC pointer is a heap object of its
own. This note measures how much each costs, sketches each change, and
recommends an order. Measured on the Intel laptop (i5-8279U, macOS 15),
`dev` at 8b61b6d, 2026-10-01.

**Decided (2026-10-01):** A is done (`sl_bytes_alloc`, below); B is
deferred; the redis client's buffer copy was fixed first (#276).

## How much it costs

Method: a scratch copy of the runtime counted every allocation by tracer
(each generated `result`/`opt` type has its own; an `opt` with a scalar
payload was given a named no-op tracer so it could be told apart from a
string buffer), symbolized with `nm`.

| workload | allocations | `bytes` headers | `result` | `opt` | representation |
|---|---|---|---|---|---|
| stdlib `redis` client, SET+GET+INCR | 287 / round | 34.8% | 8.7% | 4.2% | **47.7%** |
| `bench/suite` batch, 1M rows | 1.8M | 31.4% | 0% | 0% | **31.4%** |
| stdlib `http`, `POST /echo` 512 B | 14 / request | 21.4% | 7.1% | 0% | **28.6%** |
| zokor `examples/hello` (server + `httpc`) | 7,567 | 21.3% | 5.2% | 1.7% | **28.2%** |
| stdlib `http`, `GET /` | 11 / request | 18.2% | 9.1% | 0% | **27.3%** |
| `bench/compute` | 2.4M | 0% | 0% | 0.4% | 0.4% |
| `json.decode`, 2,000-item quote | 4,036 / request | 0.1% | 0.05% | 0% | 0.1% |

`bytes` headers are the larger share wherever a program touches the
network or files; `result`/`opt` are a third to a half of that. Code that
works on decoded data (json, compute) barely sees either.

## A. `bytes` with its data inline

**Design.** `sl_bytes_alloc(n)` makes one object, the header followed by
the data, with `ptr` pointing just past the header. `ptr` stays a real
field, so every reader (`->ptr`, `bytes_ptr`, C interop, the static
`sl_bytes_empty` and literal bytes whose `ptr` points at static memory)
keeps working; only construction changes. The tracer marks `ptr` only when
it is not inline. The runtime constructs `bytes` in exactly 12 places, all
the same shape (header, then a data buffer of known size), and nothing
reallocates or reassigns `ptr` afterwards; slicing copies.

**The blocker §5b names, examined.** Conservative scanning recognizes only
object starts, so a word holding just `b->ptr` would no longer keep `b`
alive. Which roots are conservative decides how much that matters:

- A parked or queued task is rooted *precisely*, through its safepoint
  chain. Today its `bytes` must already be rooted by the header, since the
  separate data buffer is reachable only through it. Inline data changes
  nothing here.
- An async-preempted task's stack and registers are scanned
  *conservatively*. Today a register holding only `b->ptr` keeps the data
  buffer alive, since `ptr` is that buffer's start. That is the one
  guarantee inline data would lose, and a fixed-offset check restores it:
  when a candidate word minus `sizeof(sl_bytes)` is an object whose tracer
  is `sl_gc_trace_bytes` and whose `ptr` equals the word, mark that object.
  A pointer advanced into the data (`ptr + i`) is not recognized today
  either, so the guarantee is exactly what it was.

So the blocker reduces to one check in `sl_gc_scan_conservative`, not
general interior-pointer lookup.

**A side benefit.** All 12 construction sites allocate the header, then the
data, then store the data into the header. An async preemption between the
two allocations can let a minor promote the header, and the store of a
young buffer into it has no barrier: the same hole `sl_json_b64` had until
#274. One allocation removes that window at every site.

**Measured** on the prototype that became the change: the 12 sites, the
tracer and the conservative check, about 60 lines.

- 60 bytes-, http-, json- and GC-related tests pass plainly and under
  `SLANG_GC_VERIFY_MINOR=1 SLANG_GC_NURSERY_KB=16` with forced async
  preemption, `missed=0`. Batch output hashes are identical.
- Allocations: `http.read` 7 → 6 per request, `redis` 287 → 187 per round.
- Throughput, stdlib `http`, `wrk -t2 -c50 -d8s`, ABBA, 3 rounds, first
  round discarded as warm-up: `GET /` 82.8k → 86.3k req/s (median, +4%),
  `POST /echo` 78.8k → 81.2k (+3%). The POST spread (60–84k, a throttled
  third round) is wider than the delta, so call it small and likely, not
  proven. RSS unchanged (3.5–4.2 MB).
- Batch, 5M rows, 8 workers: no measurable change (4.2–4.9 s either way).

**Cost:** about a day with tests. **Risk:** low and contained in the runtime.

## B. `result` and `opt` as values

**Design.** `result[T, E]` and `opt[T]` become C structs passed by value
(`{ok, v, e}` and `{has, v}`), never allocated. There is precedent:
a `result` whose payloads hold no GC pointer is already a value (`gen_ctor`
in `expr.c`), and value structs holding GC pointers are already rooted
(`type_has_gc_roots` in `liveness.c`).

**What it touches:**
- **The runtime.** It builds and returns `result`/`opt` pointers in about
  220 places across 11 files (fs, net, tls, io, os, sql, encoding,
  compress, crypto, regex, proc). Each signature and each caller changes.
- **Codegen.** About 60 type checks across `infer`, `liveness`, `escape`,
  `move`, `mir`, `inspect`, `generics`, `stmt` and json. Every `->ok`,
  `->has` and `->v` becomes a field access, plus guard/if-let/`??`
  lowering.
- **Containers and fields.** Rooting a payload pointer inside a value in
  registers, roots arrays, list and map slots, channel buffers and gc
  struct fields, with write barriers on every store of one into the heap.
- **Recursion.** A plain struct holding `opt[Self]` becomes infinitely
  sized, so that case needs to stay boxed, or be rejected with a
  diagnostic.

**Win:** 5–13% of allocations in network code; one allocation of the 11 in
a `GET /`. Going by A's measurements, expect low single digits of
throughput. **Cost:** a week or more. **Risk:** high: it changes how
every fallible call is rooted.

## What the measurements say matters more

The allocation *count* is not what limits these workloads. Removing 2 of
11 allocations per request moved HTTP throughput by about 4%. Three costs
found while measuring are each far larger than A or B:

- **The stdlib `redis` client copies its whole read buffer on every
  reply.** `read_reply` does `c.buf = c.buf + b` and compacts only past
  1 MB consumed: 28 GB allocated for 20,000 rounds, about 470 KB per
  command, ~250 µs per command on loopback. A fixed read buffer or
  compaction on every reply fixes it, and it should come first.
- **One `malloc` per object.** After #274, `json.decode`'s remaining time
  is allocation and GC, not parsing. A bump or size-class allocator for
  young objects cuts the cost of every allocation, not the count of a few.
- **A safepoint per loop iteration.** Batch parses 3x slower per row than
  Go single-threaded, with GC a small part of it (see `next-steps.md` §9).

## Recommendation

1. Fix the `redis` client's buffer. It's small, stdlib only, and the
   largest measured win.
2. Do **A**. It's cheap and low-risk, cuts 18–35% of allocations in I/O
   code, and removes a latent GC ordering hole at 12 sites. Pinned by the
   `http_read_wire` budget (7 → 6) and a runtime test of the conservative
   check (`tests/runtime/test_gc.c`, `sl_gc_test_inline_bytes`).
3. Defer **B**. Revisit it after the allocator work, and only with a
   measurement showing the allocation count, rather than the cost per
   allocation, still matters.
