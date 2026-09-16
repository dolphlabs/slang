# next steps

Track progress top to bottom; tick items as they land. The HTTP perf
chase is won on the raw axis (Phase E vs Go on p99 **and** RSS, PR #59
records the numbers); the ruler stays frozen and Round 2 follow-ups
live in `optimisation.md`. Error model gaps are done. Every item below is
now ticked; `crypto`, SQL, `regex`, HTTP/2, `os` and `encoding` have all
landed, and so have the two concurrency primitives (`mutex`, `select`)
at the bottom of this file.

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
- [x] HTTP/2 — multiplexing, ALPN (builds on `net` + TLS). Frame codec, full HPACK (static + dynamic table, canonical Huffman), and a connection layer serving streams CONCURRENTLY: one reader task dispatches each request to its own `spawn`ed handler, and every byte out goes through a single writer task fed by a `chan[WMsg]`. Four 500ms requests multiplexed on one connection take 0.53s against ~2.0s serialised. The writer owns the send windows because flow control is connection-wide state the READ side replenishes and the WRITE side spends — putting both in one task makes the accounting correct with no lock (slang had no mutex when this landed; it has one now, and the lock-free design still stands on its own). Deadlines are four separate budgets (handshake/idle/request/write): `idle` is generous because an open h2 connection with no streams is normal, `request` is strict and covers the request as a WHOLE, which is the only thing that stops a slowloris — a per-read timeout never fires against a peer dribbling one octet at a time. A `Transport` (fd or SSL handle) confines the h2c-vs-TLS difference to one struct, so ALPN finally has a caller; browsers speak h2 only over TLS, so without it the server could not serve one however conformant it was. Interop is against Go's `x/net/http2`, chosen because curl and nghttp2 share an implementation and agreeing with yourself is not evidence. Two bugs found by building it rather than by the suite: the reactor's deadline timer never fired for a LIVE deadline (it computed its sleep before blocking, so a deadline registered while it slept was invisible — `link`'s own `until` had therefore never worked), and nothing in the runtime ignored SIGPIPE, so any server died the first time a client hung up mid-write
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

- [x] `spawn` through a function value — closed the inconsistency the
  item above shipped with. The fix was smaller than it looked because
  the trampoline never actually needed the target's NAME, only its
  SIGNATURE, which it recovered from the name. A fn type carries the
  signature in full, so a `SpawnShape` can be keyed on the TYPE
  instead and the target travels in the args struct: one trampoline
  per fn type, calling `_sl_a->fn(...)` rather than a fixed C symbol.
  The args-struct tracer must NOT mark that field — a function value
  names code, not the heap, and marking it would hand the collector an
  address it never allocated (verified in the emitted C). Works
  through a variable, a struct field, and as an expression yielding
  `join[T]`. `pkg.func` deliberately keeps the named path so it still
  emits a direct call rather than an indirect one.

## Strings (done)

- [x] `to_int` / `to_float` builtins and a `strings` native package.
  Picked because three separate files had written the gap down:
  `demo/httpkit` ("slang has no string search/split builtins yet"),
  `demo/samplex` (`extern fn atoi`), and samplex's `path_id`, twenty
  lines of hand-rolled byte loop to read a trailing integer.

  **The atoi problem was a live bug, not an ergonomic one.** Both demos
  parsed their port with libc `atoi`, which returns 0 for `"abc"`, 80
  for `"80x80"` and 0 for `""`, reporting nothing in any case -- so
  `PORT=abc` silently bound an ephemeral port. That directly inverts
  the README's own rule about never collapsing a descriptive error.
  `to_int` returns `result[int, str]` and both demos now name the bad
  value and exit.

  Strict on purpose: whitespace, `1_000`, `0x10`, trailing characters,
  `inf` and `nan` are all rejected. A caller who wants leniency can trim
  first; a caller who gets leniency they did not ask for cannot undo it.
  The int64 range check is derived from the sign rather than assumed
  symmetric, so `-9223372036854775808` parses and
  `9223372036854775808` does not.

  `strings` is native because it has to be: `str` supports `len`, `+`
  and `==` and nothing else -- no indexing, no slicing -- so none of it
  could be written in slang without a `bytes` round trip per call. 16
  functions; `split`/`join` are exact inverses; `slice` clamps rather
  than panicking because slicing is what you do to a string you just
  searched.

  Two things fell out of it. A new `NA_ARR_STR` native arg kind, since
  `join` is the first native function to take a list. And a real parser
  fix: `strings.join` did not parse, because `join` lexes as the
  `join[T]` type keyword. Keywords now carry their spelling and any
  identifier-shaped token is accepted after a `.`, so `x.map`,
  `r.result` and `strings.join` all work. A first attempt used a token
  RANGE over the `T_TY_*` block and silently missed `chan` and `join`,
  which sit after `T_TY_LINK` in the enum -- testing by shape instead
  of by range is what makes it stay fixed.

  `bench/` and `stress_test/` still use `extern fn atoi` and are left
  alone deliberately: `bench/RESULTS.md` records "no bench changes" as
  a property of the measured runs, and editing a benchmark program to
  tidy it would invalidate the numbers taken with it.

## Packaging (done)

- [x] `make install` / `uninstall` / `dist`, `slangc new`, `--version`.
  Before this there were no tags, no releases and no install target:
  the only way to get slang was `git clone && make`, with the binary
  left in the source tree. The docs site made that worse rather than
  better -- a Packages page listing 14 packages for a language with no
  front door.

  **The bug worth remembering** is that the first install did not work.
  `slangc` splices its runtime C into every program it compiles, so the
  binary alone is useless; runtime/ and stdlib/ go to
  `$(PREFIX)/lib/slang`. But even with those in place it failed with
  "cannot find runtime file", because rtpath.c resolved relative to
  `argv[0]` -- and an installed compiler is invoked through PATH, where
  `argv[0]` is just "slangc" with no directory, so every lookup
  resolved against the CURRENT WORKING DIRECTORY. Fixed by asking the
  OS for the executable's real path (`_NSGetExecutablePath` on macOS,
  `/proc/self/exe` on Linux), with realpath so a symlinked install
  finds lib/ next to the real binary rather than next to the link.
  Verified under `env -i` with only the install prefix on PATH: source
  stdlib packages, native packages and a package with a link flag all
  compile and run.

  The installed binary is built WITHOUT `-DSLANG_RUNTIME_DIR` /
  `-DSLANG_STDLIB_DIR`. Those bake absolute paths to the build tree and
  are checked BEFORE the argv0-relative lookup, so an installed binary
  carrying them would quietly keep using the source tree it was built
  from and break the day that tree moved.

  `slangc new <name>|.` scaffolds `slang.project`, `main.sl` and
  `.gitignore`. It lives in the compiler rather than a companion tool
  because the compiler already owns both formats -- `project.c` parses
  `slang.project` and WRITES `slang.lock` -- so a separate tool would
  reimplement a grammar it does not control. It deliberately does not
  write `slang.lock`: the lock is derived from the `pkg` pins by
  `slangc get`, and a lock for a project with no dependencies records
  nothing. `cargo new` and `go mod init` draw the same line.

  The suite checks scaffolding end to end (create, build, run, and
  refuse to overwrite), and the check was confirmed to FAIL when the
  generated main.sl is broken.

  **Not done, deliberately:** no git tag and no GitHub release. Both are
  public, one-way actions; `make dist` produces the relocatable tarball
  and the tag is one command when someone decides to cut v0.1.0.


## Encoding (done)

- [x] `encoding` — hex, base64, base64url, percent-encoding, query
  strings. Native package, pure computation, no link flag (like
  `regex`/`strings`/`os`).

  **Picked by the same test the rest of this file uses: the codebase had
  already written the gap down.** `tests/crypto/main.sl` asserts on a
  SHA-256 digest byte by DECIMAL value (`expect_byte(h, 0, 186)` —
  that is `0xba` hand-converted) because slang could compute a digest
  and then had no way to display or store one. base64 had existed since
  `json` landed but only INSIDE `sl_json.c`, as a private detail of
  encoding a `bytes` field; nothing could call it. Between them that
  ruled out HTTP Basic auth, JWTs, `application/x-www-form-urlencoded`
  bodies, percent-decoded query parameters and hex digests in logs or
  ETags — for a language built primarily for server-side and network
  programming.

  **The shape is asymmetric on purpose.** Encoding never fails — any
  byte string has a hex form — so the encoders return a bare `str`.
  Decoding takes input the program did not produce, so every decoder
  returns `result[_, str]` naming the byte OFFSET it gave up at, because
  "invalid base64" about a 400-character token is not a diagnosis.

  **`str` vs `bytes` decides every return type, and is load-bearing.**
  `hex_decode`/`base64_decode` yield arbitrary bytes and return `bytes`,
  which carries an explicit length, so a decoded zero byte is ordinary
  data. `url_decode`/`form_decode` yield text and return `str`, which is
  NUL-terminated — so `%00` CANNOT be represented, and they refuse it
  rather than hand back a value silently cut short. That is the same
  rule `to_int` follows: leniency a caller did not ask for cannot be
  undone.

  **`url_*` and `form_*` are separate names rather than one function
  with a flag**, because they differ only in `+` (a space in a form
  body, a literal plus in a URI) and getting it backwards is SILENT —
  the failure surfaces much later as a lookup that does not match. A
  flag would have made that the default mistake.

  `query_get` returns `opt[str]` (a missing parameter is absent data,
  not bad data) and takes the first value; `query_keys` returns a list
  rather than a map, because a query may legally repeat a key and a map
  would have to drop one — the same reasoning that made `os.environ` a
  list. A bare `?debug` is present with an empty value, not absent.

  Two details checked against the specs rather than assumed: percent-
  escapes are emitted UPPERCASE (RFC 3986 §2.1) while hex digests are
  lowercase (`sha256sum`, git, every API that returns one), with both
  decoders accepting either case; and `base64url` omits padding (RFC
  4648 §5, what JWT uses) but TOLERATES it on the way in, since
  producers differ. The alphabets are not interchangeable and the error
  says which to try.

  Every vector in `tests/encoding/` was cross-checked against Python's
  `base64`/`hashlib`/`urllib.parse` before the expected output was
  frozen — all seven RFC 4648 padding cases, the RFC 7617 Basic-auth
  example, UTF-8 percent-encoding, and query parsing including the bare
  flag. The test was then confirmed to FAIL under three separate
  controls: `form_decode` not treating `+` as a space (the silent bug
  above), `%00` accepted instead of refused, and percent-escapes emitted
  lowercase.

  One runtime detail worth keeping: `sl_bytes_new` COPIES from its
  argument, so it cannot allocate a buffer to be filled in place —
  `sl_bytes_new(NULL, n)` memcpys from NULL. The decoders know their
  output size up front, so they allocate the same two-part shape
  directly (`sl_enc_bytes_raw`). Error messages format into a buffer the
  caller owns on its own stack rather than a `_Thread_local` one: a task
  can be async-preempted between the `snprintf` and the copy and resume
  on another worker, where thread-local storage is a different thread's.

## HTTP client (done)

- [x] `httpc` — HTTP/1.1 client over `net`, http and https. A slang
  source package, not native: it is composition over `net` + `strings`,
  with no C to write.

  **Why it was the next thing.** `stdlib/http` is entirely server-facing
  — `parse` reads a REQUEST, `serialize` writes a RESPONSE — so a slang
  service could answer calls and could not make one. No webhooks, no
  payment APIs, no object storage, no auth callback, no talking to
  another service in the same cluster. For a language built primarily
  for server-side and network programming that is a larger hole than any
  single missing syntax feature. It waited on `encoding` because
  percent-encoding and base64 are its prerequisites, not its garnish.

  **Separate package rather than folded into `http`.** `http` imports
  only `byteutil`; a client must import `net`, and an https request
  drags `-lssl`/`-lcrypto` onto the link line. Folding them would put
  that cost on every program that merely wanted to serve HTTP.

  **Transport, not `link`.** The same call `http2/conn.sl` made and for
  the same reason: `link` is move-only, and a redirect chain hands the
  connection through several frames. An fd for http, an SSL handle for
  https, behind three functions.

  **A 404 is a `Response`, not an `err`.** The `result` is about whether
  the exchange happened — DNS, connect, TLS, framing. A server that
  answers "no" answered. Collapsing them would make a 404
  indistinguishable from a connection refusal at the call site.

  **Security decisions, all verified rather than assumed:**

  - Certificates are verified and nothing turns that off. Checked
    against badssl.com: `expired`, `self-signed` and `wrong.host` are
    all refused with `certificate verify failed`; a valid cert is
    accepted. A private CA is served by `ca_path`, which is a different
    trust anchor rather than a disabled check. (The first attempt got
    this wrong in the other direction: `net.tls_client_ctx` takes a CA
    PATH, not a hostname, and passing the host made every https request
    fail with "No such file or directory". SNI and hostname
    verification are `net.tls_dial`'s job — `SSL_set_tlsext_host_name`
    plus `SSL_set1_host`.)
  - `Authorization`, `Cookie` and `Proxy-Authorization` are dropped when
    a redirect changes scheme, host or port. The server that sent the
    `Location` chose where it points, which is exactly how a token gets
    exfiltrated. Same-origin redirects keep them.
  - Credentials in a URL (`http://user:pw@host`) are REFUSED, not
    silently dropped — dropping them sends an unauthenticated request
    that returns 401 with no visible cause.
  - Every buffer a server can make the client fill has a ceiling: 64 KiB
    of headers, 32 MiB of body, a bounded chunk-size line.

  **Redirect method rules follow browsers, not the RFC's original
  wording**: 303 always becomes GET, and 301/302 after a POST do too,
  because that is what browsers and curl do and therefore what servers
  expect. 307/308 preserve the method, which is what they exist for.

  **Response framing covers all four shapes** a real server produces:
  Content-Length, chunked (with extensions ignored and trailers read and
  discarded), bodiless by status (HEAD, 204, 304, 1xx — where a
  Content-Length is advisory and believing it hangs the client), and
  framed only by the connection closing, which is why every request
  sends `Connection: close`.

  **Testing is against a canned server in the test program itself**,
  speaking raw fds, because most of these cases are response shapes a
  cooperative server will not produce on demand — a chunked body with a
  trailer, a 204 carrying a Content-Length it is not allowed to have, a
  redirect loop, a HEAD whose Content-Length describes a body that never
  arrives. Writing the bytes by hand is the only way to be sure the
  client saw them. The https path is NOT in the suite, because a test
  that needs the internet fails for reasons that have nothing to do with
  the code; it was verified by hand against example.com and badssl.com.

  Confirmed to FAIL under three controls: cross-origin credential
  stripping disabled (the `Bearer` token reached the other origin),
  302-after-POST preserving the method, and chunk extensions no longer
  ignored.

  One trap worth remembering, and it cost a compile: a test directory
  named `tests/httpc/` makes the TEST's own package `httpc`, which
  collides with the stdlib package it imports. Renamed to
  `tests/http_client/`.

  **Not done, deliberately:** no connection pooling (pooling means
  idle-connection eviction, per-host limits and a reaper task — a real
  project, built on top of this rather than inside it), no gzip (nothing
  links zlib, and advertising an encoding you cannot decode is worse
  than not asking), no cookie jar, no HTTP/2 client, no multipart
  bodies. All additive.

## Compression (done)

- [x] `compress` — gzip, zlib and raw DEFLATE over zlib. Native package,
  `-lz` gated on `want_compress`, the same shape crypto (`-lcrypto`) and
  sql (`-lsqlite3`) use.

  **zlib rather than our own, which is the opposite of the `regex`
  call.** regex was written in-house because a backtracking engine has a
  catastrophic input class and being immune to it by construction was
  the entire point. DEFLATE has no equivalent argument. What it has is
  thirty years of hostile input and a reference implementation on every
  platform slang targets, and every bug in a hand-written inflate is a
  buffer overrun driven by attacker-controlled input — a memory-safety
  surface with no upside.

  **Decompression takes a MANDATORY output limit.** `max_out` is a
  required argument, not an optional one with a generous default,
  because the expansion ratio is unbounded and a default would be a
  number nobody chose applied at every call site that never thought
  about it. The ceiling is enforced before the allocation that would
  cross it rather than by inspecting the result: a 65,250-byte gzip
  holding 64 MiB was refused at **3.9 MB peak RSS** against a 0.86 MB
  baseline for the same program without the call.

  **Three containers because HTTP needs three.** Same bits, different
  headers: gzip (RFC 1952) is what servers send, zlib (RFC 1950) is what
  the `deflate` content-coding is supposed to mean, and raw (RFC 1951)
  is what the servers that get it wrong send instead — so `inflate_raw`
  is a compatibility requirement, not a completist's flourish.
  `deflate_raw` exists so `inflate_raw` has an inverse to be tested
  against, and because permessage-deflate (RFC 7692) needs it.

  **Format correctness is checked against the system tool, not against
  itself.** slang's gzip output is read by `gzip -dc`, and `gzip`'s
  output is read by `compress.gunzip`. Agreeing with your own encoder
  proves nothing, which is the same reasoning that put the HTTP/2
  interop test against Go's `x/net/http2` rather than curl.

  **Two controls landed and one did not, which was the useful part.**
  Confirmed failing: gunzip made to auto-detect zlib (the containers
  must not be interchangeable), and empty input silently returning empty
  rather than erroring. NOT caught: an off-by-one in the ceiling — and
  chasing why exposed that the boundary the test named was not the
  boundary the code turned on, because the geometric doubling never
  lands on `max_out - 1`. The limit now measures what was PRODUCED
  instead of inferring "too big" from a full buffer, with one byte of
  allocation slack so an exact-size output never depends on when zlib
  chooses to report `Z_STREAM_END`.

  Stated plainly because it would be easy to imply otherwise: removing
  that slack byte does **not** fail the test on this zlib (1.2.12),
  which reports `Z_STREAM_END` on the filling call. The guard protects
  against behaviour that could not be reproduced here. What IS
  demonstrated is the post-loop size check (removing it breaks the
  one-byte-short case) and the in-loop ceiling, whose removal makes the
  grow loop **spin** rather than over-allocate — which is how the
  no-progress guard in the inflate loop got written.

## HTTP client: pooling and decompression (done)

- [x] `httpc.Client` with connection pooling, and transparent gzip /
  deflate decoding. Cookies are the next and separate piece.

  **One code path.** The one-shot `httpc.get` / `post` / `head` / `send`
  are a `Client` with `max_idle_per_host = 0`. Framing, redirects,
  decompression and every security rule therefore cannot drift between
  the pooled and unpooled paths, because there is only one.

  **Stale connections are detected by a new primitive, not a timing
  trick.** Servers close idle connections on their own timers (Node's
  default is 5s). The obvious probe — `recv_until` with an
  already-expired deadline — does not work, and the reason was found by
  reading `sl_net_recv_u` rather than by testing: it checks the deadline
  BEFORE touching the socket, so it would report every dead connection
  alive. `net.idle_alive` / `net.tls_idle_alive` are one non-blocking
  `MSG_PEEK`: no latency, nothing consumed, verified in all three
  states (open and quiet, peer sent a byte, peer closed).

  **Retry is idempotent-only.** A reused connection that dies before the
  first response byte is retried once on a fresh connection for
  GET/HEAD/PUT/DELETE/OPTIONS/TRACE. POST is never resent, because it may
  already have been acted on. The probe protects POST; retry is the
  backstop for the race between probe and write.

  **The pool key includes `ca_path`**, so a connection verified against
  one trust anchor is never reused for a request that demanded another.
  Tested over real TLS with two different certificates.

  **Decompression follows Go's rule:** requests advertise gzip/deflate
  and responses are decoded ONLY when the caller did not set
  Accept-Encoding. Decoded size shares the 32 MiB body ceiling, so a
  gzip bomb in a response is refused. `deflate` tries zlib and then raw
  DEFLATE, since a real share of servers mislabel raw.

  **The test checks the pool from both ends.** The canned server counts
  the connections it actually accepted, and that must agree with the
  client's own `dials` / `reuses`. Under 16 concurrent tasks the
  invariant `dials + reuses == requests` must hold exactly. 30/30 stable.

  **Nine controls, all caught — but three only after the test was
  fixed, which is the point of running them.**
  - A "close-delimited" reader flag could never change the outcome (a
    close-delimited body always ends at EOF, which already blocks
    reuse). Removed as dead state rather than kept.
  - Ignoring the server's `Connection: close` was masked by the probe:
    the test server also closed, so the dead connection was discarded on
    the next request anyway. A server that says close and lingers would
    have slipped through. Fixed by asserting the reuse DECISION directly
    with `httpc.idle_count`.
  - Dropping `!r.eof` from the reuse check was masked because a
    non-empty close-delimited body is still in the read buffer. Only an
    EMPTY close-delimited body isolates it; that case now exists.
  - Removing the CA path from the pool key was not exercised at all
    until the TLS section existed. It is the one that matters most.
  - Removing the pool lock: 64/160 concurrent requests succeeded.

  **Building the TLS test exposed a runtime memory-safety bug** — stack
  relocation leaving compiler-hoisted stack addresses dangling — fixed
  separately in PR #120 before this landed. See todo.md.

  **Two language limits hit and routed around, not fixed here:**
  - A method cannot share a name with a package function
    (`impl Client { fn get }` collides with `httpc.get`); methods are
    emitted under the same C symbol. Client operations are therefore
    handle-first functions, `client_get(c, ...)`, matching every other
    stdlib package (`sql.exec(db, ...)`).
  - `pub fn` inside `impl` is documented in the README but rejected by
    the parser, and method visibility is not enforced at all
    (`method_find` checks only package and name).
  - Separately: `==` between two `bool`s is a compile error.

## HTTP client: cookies (done)

- [x] Cookie jar on `httpc.Client` — RFC 6265, with 6265bis's `Secure`
  and `__Secure-` / `__Host-` rules. Completes the three-part request
  (compression, pooling, cookies).

  **Off by default, the opposite of a browser.** A server's Client is
  usually shared across the users it serves; a jar there sends user A's
  session on user B's request. `enable_cookies` scopes a Client to one
  identity. Go's `http.Client` (Jar nil) makes the same call.

  **A pre-existing bug fixed on the way:** `parse_headers` joined
  repeated headers with `", "`, and its comment claimed that kept two
  Set-Cookie lines as two cookies. It did the opposite once a cookie
  carried an `Expires` date, which contains a comma — joined lines
  cannot be split back apart. RFC 9110 exempts Set-Cookie from joining
  for exactly this. `Response.set_cookies` now holds each line.

  **Per-hop, not per-request.** Cookies are stored from every response
  in a redirect chain and computed for every hop, so a cookie set by a
  302 reaches its target (how login flows work) and a redirect to another
  host carries that host's cookies.

  **`set_cookie(c, url, line)` exists because the test could not see
  three security bugs without it.** The first refusal checks inspected
  the jar from the host that sent each cookie, over http, and all three
  of the most important refusals passed with their checks DELETED:
  - a wrongly stored Secure cookie is still not SENT over http,
  - a wrongly stored `Domain=evil.example` cookie does not match
    127.0.0.1,
  - and `Domain=com` from 127.0.0.1 is refused by the foreign-domain
    rule before the TLD rule is ever reached.
  The storage was wrong and the test was blind to it. Checking from the
  URL that would EXPOSE a wrongly stored cookie needs hosts like
  `a.example.com`, which loopback cannot provide; `set_cookie` applies a
  line through exactly the path a response takes (Go's `Jar.SetCookies`
  equivalent, and also how a program restores a saved session).

  **The concurrency check was blind the first time too.** 16 tasks
  writing 400 cookies against a 50-per-domain cap "passed" with the lock
  removed, because later writes refilled the jar to 50. Rewritten to 48
  cookies, under the cap: without the lock, 23 / 19 / 16 survived across
  three runs.

  17 controls in all, every one caught after those fixes. Cookie-date
  expected values come from Python's `calendar.timegm`, not the parser
  under test. 25/25 stable.

  **Not done, and stated in the README rather than left to be found:**
  no public-suffix list, so `Domain=co.uk` from `a.example.co.uk` is
  accepted and sent to every `*.co.uk` host. A bare TLD is refused; that
  case is not.

## Notes

- Do not change `bench/http/main.sl` for perf experiments. Raw-best slang is `bench/http_opt/main.sl`; remasure with `./bench/run_http_opt.sh`.
- Do not start LLVM.
- Phase E claim requires p99 **and** RSS vs Go; RPS alone is not a win.
