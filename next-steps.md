# next steps

Track progress top to bottom; tick items as they land. The HTTP perf
chase is won on the raw axis (Phase E vs Go on p99 **and** RSS, PR #59
records the numbers); the ruler stays frozen and Round 2 follow-ups
live in `optimisation.md`. Error model gaps are done. Every item below is
now ticked; `crypto`, SQL, `regex`, HTTP/2 and `os` have all landed,
and so have the two concurrency primitives (`mutex`, `select`) at the
bottom of this file.

## HTTP perf (won on raw axis, ruler frozen)

- [x] Spawn-inline args (`sl_task_submit_copy`, no heap alloc per accept)
- [x] Profile VM under wrk c=50 (safepoint/checkin on serve path, not freelist)
- [x] Revert MPSC task freelist (no win; profile said ~0.2%)
- [x] Revert Linux TLS-inline of `sl_rt_cur` (segfault: `sl_ctx_switch` onto rsi=0)
- [x] Hoist for-in safepoint to once per loop (roots iterable alias)
- [x] Raw-axis Phase E vs Go on **both** p99 and RSS (`optimisation.md`, PR #59)

## Error visibility + log (done)

Errors are easy to **handle** (`guard let`, `??`, `fault`) and hard to
**see** (else branch throws away `E`, no levels, no context).

- [x] Pick error-access shape: `guard let x = r else let e = err_of(r) { ... }`
- [x] Implement chosen shape in parser + codegen + tests
- [x] `to_str(fault)` via `sl_str_from_fault`
- [x] `log` package: debug/info/warn/error to stderr with timestamp
- [x] `log` accepts `str` or `fault`, `fault` concatenates with `+`
- [x] Demo: HTTP/TLS handlers log parse/I/O failures via `err_of`

## Language features (all done)

- [x] `crypto` — hash (SHA-256), HMAC, CSPRNG (PR #68: native package over OpenSSL; `sha256`/`hmac_sha256` return `bytes`, `rand` returns `result[bytes, str]`; `-lcrypto` gated on `want_crypto`)
- [x] SQL — driver + `result`/connection errors wired through same visibility story (native `sql` package over SQLite; prepared-statement API with `rawptr` handles like `net.tls_*`; every fallible call is `result[_, str]` carrying `sqlite3_errmsg`; `-lsqlite3` gated on `want_sql`. Added `NA_I64`/`NA_F64` native arg kinds so bind values stop truncating through the default i32 marshal. Two independent green-thread hazards, both found by stress rather than by the suite: SQLite recursed past the 8KB task stack into the heap (13/100 runs aborted in malloc) — fixed with `sl_rt_need_stack`, TLS's `need_fat_stack` generalized; and async preemption resumed a task on another worker mid-call, breaking SQLite's thread-owner-tracked mutexes (9/15 runs SIGILL at 2000 concurrent tasks) — fixed with preempt brackets. Stack size is derived, not guessed: `sqlite3_limit` caps compound SELECT at 50 and expr depth at 400, holding the worst legal query to 35,464 measured bytes inside 64KB. 64KB over 256KB is worth 20MB RSS at 600 concurrently-live sql tasks)
- [x] `regex` — compile/match on `str` or `bytes` (slang's own Thompson NFA / Pike VM in `runtime/sl_regex.c`; **no external dependency**, so unlike crypto/sql it adds no link flag. `compile -> result[rawptr,str]` with descriptive parse errors, `is_match`/`find` on `str` or `bytes` with explicit length so NUL is an ordinary byte, `find` returns `[int]` offsets — empty means no match, GC-owned, no handle to leak. Linear time by construction: `(a+)+$` on hostile input is 2us here vs PCRE2's 0.2s-then-`MATCHLIMIT`. Price is RE2's: no backreferences, no lookaround. Measured single-threaded ~721k matches/sec — 1.9x libc POSIX, but 3-10x slower than PCRE2 interp/JIT on benign input; closing that needs a lazy DFA, which is a real project. ~3.2M/sec across 16 tasks, ~1.06MB RSS, match buffers pooled lazily so concurrent matchers allocate nothing. Compile grows the task stack once; matching never does — 600 concurrently-live matching tasks peak at 3.9MB RSS, ~17x lighter than the same shape holding sql connections (65.9MB). Three self-inflicted bugs worth remembering: an uninitialised sparse-set read (40% segfault), left-deep parse trees that would blow the 8KB stack on long patterns, and 43 unbracketed mallocs causing `_os_unfair_lock_unowned_abort` — the same preempt-bracket rule `sl_gc_alloc_fin` and `sl_crypto.c` already follow)
- [x] HTTP/2 — multiplexing, ALPN (builds on `net` + TLS). Frame codec, full HPACK (static + dynamic table, canonical Huffman), and a connection layer serving streams CONCURRENTLY: one reader task dispatches each request to its own `spawn`ed handler, and every byte out goes through a single writer task fed by a `chan[WMsg]`. Four 500ms requests multiplexed on one connection take 0.53s against ~2.0s serialised. The writer owns the send windows because flow control is connection-wide state the READ side replenishes and the WRITE side spends — putting both in one task makes the accounting correct with no lock, which slang does not expose anyway. Deadlines are four separate budgets (handshake/idle/request/write): `idle` is generous because an open h2 connection with no streams is normal, `request` is strict and covers the request as a WHOLE, which is the only thing that stops a slowloris — a per-read timeout never fires against a peer dribbling one octet at a time. A `Transport` (fd or SSL handle) confines the h2c-vs-TLS difference to one struct, so ALPN finally has a caller; browsers speak h2 only over TLS, so without it the server could not serve one however conformant it was. Interop is against Go's `x/net/http2`, chosen because curl and nghttp2 share an implementation and agreeing with yourself is not evidence. Two bugs found by building it rather than by the suite: the reactor's deadline timer never fired for a LIVE deadline (it computed its sleep before blocking, so a deadline registered while it slept was invisible — `link`'s own `until` had therefore never worked), and nothing in the runtime ignored SIGPIPE, so any server died the first time a client hung up mid-write
- [x] Second `os` package — env beyond `proc`, argv, cwd, file metadata (avoid duplicating `fs`). Native package over libc, so unlike crypto/sql it adds no link flag. The boundary that keeps it from duplicating `fs`: `fs` owns open file HANDLES and their contents, `os` owns paths you have not opened, plus the environment and the process (`fs.mkdir` predates the split and stays put). Env gets set/unset/environ — `proc.getenv`/`args`/`cwd` stay in `proc` rather than being mirrored. Metadata is `exists`/`is_dir`/`is_file` as bare bools and `size`/`mtime` as `result[int,str]`: a predicate has two useful answers (a missing path and an unreadable parent are both "no", and branching on the difference is racing anyway), while an accessor returns a value that has to come from somewhere and so carries the errno text. `environ` is a list not a map, because an environment may legally repeat a key and a map would silently drop one; `read_dir` omits `.`/`..`, forgetting which is how a walk becomes an infinite loop; `remove` takes files and empty directories alike. Every libc call that allocates or walks kernel structures is preempt-bracketed, the same rule sl_sql.c needed

## Error model gaps (done)

- [x] `opt` none vs `result` err vs `fault`: documented rule + stdlib audit (PR #63: README rule — absent data is `opt`, bad data is `result[_, str]`, bad world is `result[_, fault]`; `http.parse` threads `err_of` context, `http.read` returns `result[Incoming, str]` with descriptive errors)
- [x] Richer `fault` context without breaking the closed enum (PR #64: `op` + `code` on `sl_fault`; `==`/`fault_kind` kind-only; `fault_op`/`fault_code` accessors; net tags send/recv/accept/dial/connect with op + errno)
- [x] Panic message quality (PR #65: `sl_rt_error_at` threads `pkg.func:line` through div-by-zero, `err_of`-on-ok, map-missing-key, and list/bytes/wire bounds; `join_wait` surfaces the located string)

## Concurrency primitives (done)

Both of these were picked because the stdlib had already written the
workaround down as a comment, which is the strongest evidence a gap is
real: `stdlib/http2/conn.sl` noted the missing mutex, and
`demo/samplex/server.sl` was emulating one with a `chan[bool]` holding
a single token.

- [x] `mutex` — `make_mutex()` / `mutex_lock` / `mutex_unlock` /
  `mutex_trylock`. Parks the TASK, not the worker thread: holding a
  real pthread lock across user code would block an OS thread and
  starve every task queued behind it, the same reason `chan` parks
  rather than using a condvar. Needed no lexer or parser change —
  `mutex` rides the same soft-name path `trip`/`peer`/`wire` already
  use, so it is three table entries plus the builtins. Two conditions
  are checked rather than left to chance, both because they otherwise
  present as something other than what they are: a recursive lock
  would park the task forever on itself (a hang is the least useful
  diagnosis available), and unlocking someone else's mutex shows up
  much later as corruption in whatever the lock protected. The test is
  a real one — 8 tasks × 2000 increments is exactly 16000 on 20/20
  runs, and the same program with the lock/unlock pair deleted scores
  5035/7343/6204/5880/6717, so it fails without the thing it tests.
  `demo/samplex` converted and verified end-to-end: 200 concurrent
  POSTs produce 200 tasks with 200 unique ids. `http2` deliberately
  NOT converted — its single writer task also guarantees HEADERS and
  CONTINUATION are never split by another frame, which a lock does not
  give
- [x] `select` over channels — the harder half. The blocker is
  structural, not syntactic: `sl_task.next` is the link for BOTH the
  run queue and a channel's wait list, safe today only because "a task
  is on exactly one such list at a time" (`sl_containers.c`). `select`
  needs one task on N wait lists at once, so it needs per-waiter nodes
  (Go's `sudog` shape) rather than linking the task itself, plus a
  claim protocol so exactly one channel wins the wake. One
  simplification is already in hand: slang channels are always
  buffered (`sl_chan_new` clamps `cap` to >= 1), so a woken select can
  just re-try every case instead of being handed a value directly —
  no rendezvous handoff to get wrong

  **Landed.** All of the above held up. Wait lists now hold `sl_waiter`
  NODES allocated on the parked task's own C stack, so nothing
  heap-allocates and chan stops writing `sl_task.next` altogether —
  which structurally retires the async-preemption hazard the old code
  needed a bracket for (the brackets stay; they also cover the park
  transition). Syntax reuses the existing builtins rather than
  inventing an arrow operator: `case let v = chan_recv(a) { }`,
  `case chan_send(b, v) { }`, `default { }`. A recv arm binds `opt[T]`
  exactly as `chan_recv` does, so a closed channel is `none` and needs
  no second convention.

  **The bug worth remembering.** A select cannot hold N channel locks
  at once, so unlike `chan_recv` it cannot stay locked from "is there a
  value" through "put me on the wait list" to the park. A sender
  landing in that window finds an empty wait list, wakes nobody, and
  leaves — and a select that parks without looking again loses that
  wakeup permanently. Found as a hang (1 run in ~30, every worker idle
  in `sl_worker_run_loop`), fixed by polling a SECOND time after
  enqueueing. `tests/select_stress` is built around it: 300 rounds that
  each END, because steady traffic hides the bug completely. An earlier
  version of that test kept producers running for the whole program and
  passed 20/20 with the fix REMOVED — that near-miss is worth more than
  the test was. The round-based version hangs 19/20 without the fix and
  passes 60/60 with it; `tests/select` (the original repro) went
  150/150.

  **Not supported:** no timeout arm, and no way to disable an arm (Go
  uses a nil channel; slang has none), so a closed channel's recv arm
  is ready forever and a loop that keeps selecting on it will spin. A
  timeout arm needs the `sl_time` sleepers list to gain a removal
  operation and select to coordinate two wake sources; the claim
  protocol already generalises to it.

## Function values (done)

- [x] `fn(A,B) -> R` as a type, holding a top-level function. Picked
  over full closures deliberately: the hard parts of closures are all
  in the CAPTURE (heap-allocating an environment, tracing it, making
  it agree with the borrow checker), and none of that is needed for
  the thing the codebase actually kept wanting — a dispatch table. A
  value that captures nothing is exactly a C function pointer: it
  names code, never the heap, so `type_is_gc_ptr` is 0 and the
  collector ignores it. The README's "no closures" position stays
  true, and closures remain strictly additive later.

  Two implementation notes worth keeping. **Typedefs**: C puts the
  declarator's name inside a function-pointer type (`R (*f)(A)`), which
  cannot be spliced into this codegen's `"<ctype> <name>"` shape — so
  every distinct fn type gets a `typedef`, the same monomorphisation
  trick `opt`/`result` already use. Emitting them means splitting the
  struct forward declarations from the struct bodies, because the
  dependency is genuinely circular (a struct field may hold a function
  value; a function type may take a struct) and only the fn typedef can
  tolerate an incomplete type. **Calls**: `EX_CALL` gained a `callee`
  expression alongside `name`, so `routes[i].handler(req)` parses;
  `name` keeps a non-NULL sentinel rather than becoming NULL, because
  ~20 sites across the passes read it unconditionally and a sentinel
  that cannot collide with a real identifier makes all of them safe at
  once. A NULL there segfaulted the compiler in `strchr`.

  A fn-typed FIELD beats a method of the same name, since the parser
  folds one dot into the call's name and both shapes arrive at the same
  place. Methods are not usable as values at all (they take a receiver
  the type does not name) — `spawn` already draws that line.

  `demo/samplex` converted as the proof: the `if path == ... if method
  == ...` chain is now a four-row table, verified end to end on every
  route plus the 404/405 split, and 200 concurrent POSTs still produce
  200 unique ids.

  Not supported: `spawn` still requires a named function, not a
  function value.

## Notes

- Do not change `bench/http/main.sl` for perf experiments. Raw-best slang is `bench/http_opt/main.sl`; remasure with `./bench/run_http_opt.sh`.
- Do not start LLVM.
- Phase E claim requires p99 **and** RSS vs Go; RPS alone is not a win.
