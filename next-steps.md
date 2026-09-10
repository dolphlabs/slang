# next steps

Track progress top to bottom; tick items as they land. The HTTP perf
chase is won on the raw axis (Phase E vs Go on p99 **and** RSS, PR #59
records the numbers); the ruler stays frozen and Round 2 follow-ups
live in `optimisation.md`. Error model gaps are done. Every item below is
now ticked; `crypto`, SQL, `regex`, HTTP/2 and `os` have all landed.

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

## Notes

- Do not change `bench/http/main.sl` for perf experiments. Raw-best slang is `bench/http_opt/main.sl`; remasure with `./bench/run_http_opt.sh`.
- Do not start LLVM.
- Phase E claim requires p99 **and** RSS vs Go; RPS alone is not a win.
