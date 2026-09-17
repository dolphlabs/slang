# next steps

Work top to bottom, one item at a time; tick items as they land.

Everything finished before v0.2.0 was cleared from this file to keep it
short. The full write-ups — why each design was chosen, what was measured,
which controls caught what — are in git history and the PR descriptions:
`git show eeefce1:next-steps.md`. Runtime bugs and their investigations
live in `todo.md`.

## 1. Linux CI

- [x] **x86_64:** `.github/workflows/ci.yml` builds `slangc`, runs the full
  suite and the docs build on Ubuntu 24.04 on every merge to `main` (and
  on manual dispatch), and attaches a verified Linux tarball to every
  published release. First run on `main` went green: 176/176 on
  GitHub's Ubuntu runner.

  Reproduced locally in Docker before writing the workflow, and the first
  Linux run found **three bugs that had shipped**:
  - `tests/runtime/test_gc` was a committed macOS binary. A fresh checkout
    made `make` think it was built, so Linux tried to execute a Mach-O
    file before any test ran.
  - **No slang program linked on Linux**, hello included. The preemption
    and context-switch trampolines call four C functions from top-level
    `__asm__`, which GCC's `-flto` cannot see into, so it discarded them.
    clang on macOS kept them by chance. Now `__attribute__((used))`.
  - `json` decoded `int` (C `long long`) through an `int64_t *`. Same type
    on macOS, different on Linux glibc, where GCC flagged it in every
    program decoding an int field.

  After those: 176/176 on Linux x86_64 with GCC 13, generated C
  warning-free under GCC as well as clang. The Linux tarball was verified
  with the source tree deleted, including through a symlink on PATH, which
  exercises the never-before-run `/proc/self/exe` lookup.

- [x] **arm64** — Linux arm64 and Apple Silicon. Neither had ever built:
  the async-preemption and stack-growth trampolines existed only in x86_64
  assembly, so every program failed to link.

  **The design is not a translation of x86_64.** x86_64 resumes the
  interrupted code by jumping through a slot below `%rsp`, which is sound
  only because of its 128-byte red zone. arm64 has no red zone and no
  memory-indirect branch, and branching back needs a register that, at an
  arbitrary interrupted instruction, may be live. So the kernel does the
  final restore: the trampoline saves every register, yields, then raises
  SIGUSR2 on its own thread; the handler writes the saved registers, sp,
  NZCV and the original pc into the signal context, and sigreturn restores
  all of them atomically. Linux restores vector state in assembly and
  raises the signal with raw syscalls (so SVE-capable hardware can't make
  the kernel ignore a handler's FPSIMD edits); Apple, with no SVE and no
  stable syscall ABI, goes through `pthread_kill` and restores NEON in the
  handler. Both signal handlers run on a per-thread alternate stack, since
  an arm64 signal frame (~4.6KB+) could overflow an 8KB task stack.

  **Verified on native runners**, by manual dispatch of the branch before
  merging: 176/176 on Linux arm64 and on macOS arm64. A new CI step forces
  genuine async preemption — the suite's own probe never did, because its
  loop yields cooperatively — and fails if none happened: 150 async
  preemptions on Linux arm64 and 70 on Apple Silicon across five runs,
  every result correct. Under QEMU emulation, ~1,700 per run, also correct.

  **Two controls, and the first was weak.** Skipping `x19`–`x28` in the
  resume handler failed macOS but PASSED Linux: on Linux the signal is
  raised from the trampoline itself, after C calls that preserve those
  registers by convention, so the kernel's frame already held them. Only
  the registers the trampoline clobbers depend on the handler there.
  Skipping `x0`–`x18` failed BOTH (wrong totals, panicked tasks), which is
  the evidence the check detects a broken restore on each platform.

  Accepted limit, the same as x86_64 with AVX-512: only the low 128 bits of
  each vector register survive a preemption.

## 2. OpenSSL discovery fallback

- [x] `find_openssl` (`src/main.c`) tries, first hit wins: `OPENSSL_DIR`,
  `pkg-config`, the standard Homebrew prefixes (Apple Silicon, Intel, the
  older `/usr/local/Homebrew` layout) and MacPorts, `brew --prefix`, then
  the system headers. A prefix counts only if `include/openssl/ssl.h` is
  really there.

  Found while verifying the v0.2.0 tarball: an https or `crypto` program
  failed with `'openssl/sha.h' file not found` whenever `pkg-config` was not
  on PATH or could not see a keg-only Homebrew OpenSSL.

  **Not finding it is not an error.** A compiler can have include paths
  slangc cannot see (CPATH, a sysroot, a wrapper), so refusing to compile
  would block working setups. Instead, if compilation fails and OpenSSL was
  not located, slangc adds a note worded as a condition ("if the error above
  is about openssl/ headers…") rather than a diagnosis it cannot be sure of.

  Verified on both sides of the change: with no `pkg-config` or `brew` on
  PATH, and with `pkg-config` unable to see OpenSSL, the compiler from
  `dev` failed with the missing-header error and the new one compiles. On
  Linux, the system-headers route works with `pkg-config` blind, and with
  OpenSSL removed entirely the note appears. CI now exercises the fallback
  on every platform, and the macOS job no longer sets `PKG_CONFIG_PATH` by
  hand, so its suite uses slangc's own discovery.

  **Found along the way, on the macOS runner:**
  - `tests/proc` failed about 1 run in 5: it needed a 20ms sleep to finish
    before a 150ms one. Measured on the runner, a 20ms sleep took up to
    167ms, and plain C `nanosleep` up to 126ms on the same machine, so the
    overshoot is the virtualised runner's, not slang's. The test now holds
    its task on a channel instead of racing timers.
  - `tests/sigpipe` failed twice in ~255 runs and never reproduced alone or
    under load. It is recorded in `todo.md` rather than changed on a guess.
    Its failure printed nothing useful, for two fixable reasons: `--run`
    flattened every exit status to 1, and the test runner never printed a
    failing test's stdout. `--run` now passes the program's exit code
    through (128+N for a signal, with a message), and failures print both.

## 3. `slangc test`

- [x] `slangc test [dir] [--run substr] [--keep]`, plus two builtins,
  `assert(cond[, msg])` and `panic(msg)`, usable anywhere.

  **Go's shape, because it is proven and familiar:** `*_test.sl` files,
  excluded from normal builds, holding `fn test_*()` functions inside the
  package they test, so tests reach private functions and globals.

  **Failure is a panic in the test's own task.** `assert`/`panic` end the
  current task with a located message; in a spawned task that becomes the
  `err` of `join_wait`. The runner spawns each test and joins it before
  starting the next, so a failure is reported with its message and
  location and the run continues. `assert`'s message is built only when it
  fails. `panic` is noreturn, so it can end a function that must return a
  value and satisfies `guard`'s else.

  **How:** discover the tests by parsing `*_test.sl`, generate a runner
  program that imports the package under test (by a computed relative
  path, since imports resolve relative to the importer) and calls each
  test, and compile it with the ordinary pipeline, factored out of `main()`
  into `build()`. The loader's test mode adds the test files, exports only
  the `test_*` functions to the runner, and for a PROGRAM drops the
  top-level statements, because the runner is `main` now. A library keeps
  its top-level `let`s, which are package globals.

  **A real compiler bug, found building it:** `join_wait(spawn f())` written
  inline evaluated its argument TWICE. When `f` failed, the error path
  spawned `f` again to ask the fresh copy for its error, so every side
  effect of a failing task ran twice and the real message became "task
  panicked". Confirmed on the compiler from `dev` (the task's output printed
  twice). Fixed by evaluating the handle once and keeping it a GC root for
  the whole wait: written inline, the join object is referenced only by that
  expression. Regression test: `tests/join_inline_spawn`.

  **Verified:** 182 passing. The suite drives `slangc test` end to end
  against fixture packages in `tests/testcmd/` (a library, a program whose
  top-level code would `exit 7` if run, a bad test signature, a package
  with no tests, the `--run` filter), and checks that a normal build of the
  program contains no test code. Two controls confirmed the checks bite:
  keeping a program's top-level code under test, and letting `*_test.sl`
  into normal builds, each failed the section.

## 4. Chunked request bodies in the `http` server

- [x] `Transfer-Encoding: chunked` requests, in `read` and `parse`, which
  now share one framing function so they cannot disagree about the same
  bytes. Chunk extensions ignored; trailers read and discarded (merged into
  headers, a trailer could rewrite one after the handler checked it).

  **Two request-smuggling holes, found in the framing code and confirmed
  against the old code before fixing:** two disagreeing `Content-Length`
  headers were accepted with the last one silently winning, and
  `Content-Length: 18446744073709551619` (2^64 + 3) wrapped to 3, leaving
  the rest of the body to be read as the next request. Now refused, along
  with `Transfer-Encoding` plus `Content-Length`, `Transfer-Encoding` in
  HTTP/1.0, coding lists, bare LFs, and oversized size lines and trailers.

  **A denial of service, found by testing with real clients:** reading a
  request was quadratic in its size, because `copy_wire` rebuilt the
  receive buffer a byte at a time (`out = out + one_byte`) on every recv.
  Measured on the old code: a 50KB POST took 1.0s and a 200KB one 24.7s, of
  CPU. `to_bytes` now accepts a `wire` and copies it once: 200KB, chunked
  or not, in under 10ms.

  **Verified:** `tests/http_chunked` covers decoding (extensions, trailers
  not merged, 2000 one-byte chunks), every refusal, a body split across
  seven sends, a chunked request pipelined with the next one, and a body
  larger than the buffer; 25/25 stable. Six controls each caught their bug.
  Real clients: curl's and Python `http.client`'s chunked uploads decode
  correctly, and TE+CL, duplicate `Content-Length`, the overflow and a bare
  LF each get a 400 naming the reason over a real socket.

## 5. Methods that share a name with a package function

- [x] `impl T { fn get }` now coexists with a package-level `fn get`, and
  two structs in one package may each have a method of the same name.

  Methods now live in their struct's namespace. `sig_find_in` finds only
  package-level functions; methods are found through their struct; a
  method is redefined only by another of the same name on the same struct.
  Each gets its own C symbol (`sl_<pkg>_<Struct>__m_<name>`, via
  `mangle_sig`), and passes that walk declarations take each one's
  signature from the declaration itself rather than looking it up by a
  name that is no longer unique. Because identifiers may contain `__`, a
  function that would spell a method's symbol is refused by name at
  compile time rather than left as a duplicate definition in the C.

  `httpc` gained the method forms this blocked: `c.get(url, dl)`,
  `c.post(...)`, `c.idle_count()`, `resp.header(name)` and the rest, beside
  the function forms, which stay.

  **Verified:** `tests/method_fn_same_name` covers a method matching a
  package function and a method of the same name on two structs, in both
  directions across a package boundary, plus `spawn` and function values.
  Three negative tests: a method redefined on one struct, a bare call to a
  name that exists only as a method, and a symbol collision. Two controls:
  mangling methods like functions fails the positive test (caught by the
  collision check), and letting `sig_find_in` return methods lets
  `close(s)` compile against `Store.close` -- which the method-as-function
  test catches; the positive test alone did not, because functions are
  registered first and always win the lookup. `tests/http_client_pool`
  checks the method forms pool exactly like the functions.

## 6. Postgres driver

- [x] `stdlib/pg`: a Postgres client in slang over `net`, so a query
  waiting on the server parks its task instead of blocking a worker (taken
  ahead of item 5, which is still open).

  **What it does:** SCRAM-SHA-256, md5 and cleartext login; TLS negotiated
  in-band; parameterised queries on the extended protocol and
  multi-statement `exec` on the simple one; typed getters; server errors
  with their SQLSTATE; a pool that never hands on a connection still
  inside a transaction; a deadline on every call, whose expiry sends a
  CancelRequest from its own task.

  **Security choices, each deliberate:** `sslmode=require` verifies the
  certificate and hostname (libpq's does not); `prefer`/`allow`/
  `verify-ca` are refused; unknown url parameters are errors, so a typo
  cannot silently mean cleartext; the default is TLS except for loopback
  hosts. SCRAM refuses a server that skips or fails its own proof.
  Reading exactly one byte after SSLRequest avoids libpq's
  CVE-2021-23222. Server-chosen sizes are capped (256 MiB message and
  result, 1M SCRAM iterations).

  **New natives it needed:** `net.tls_upgrade` (STARTTLS on an fd, sharing
  `tls_dial`'s verification), `crypto.pbkdf2_sha256`, `crypto.md5`, and
  `strings.from_float` (shortest round-trip text).

  **A compiler bug, found building it:** float LITERALS were emitted into
  the C with `%g`, six significant digits, so `3.141592653589793` compiled
  to `3.14159` and `123456789.125` to `123457000`. Now the shortest
  round-trip form. Regression test `tests/float_literal`; the control
  (six digits again) fails it.

  **Performance, found by measuring:** the first version kept one `bytes`
  per cell and took 35.8s for 1M rows (2.5s for 200k: quadratic, all GC
  marking). Cells now point into the receive buffers themselves, with no
  per-row allocation: 2.1s and 150MB for 1M rows, 0.4s for 200k, a 20MB
  value in 0.3s. The GC pacing behind the original cliff is recorded in
  `todo.md` as a lead; a pacing change helped the old design but measured
  nothing on the new one, so it was not shipped.

  **Verified:**
  - `slangc test stdlib/pg` (in `make test`): URL parsing and refusals,
    and SCRAM against RFC 7677's published exchange.
  - `tests/postgres`: scripted fake servers for what a real one will not
    do. That covers the Bind encoding on the wire, md5 (answer computed
    independently), four dishonest SCRAM servers, and a COPY refused and
    resynchronised. It also covers six malformed or truncated streams,
    each breaking the connection, a timeout that sends a correct
    CancelRequest, getter panics, and pool exhaustion, transaction
    discard, double release and close.
  - 16 controls, each disabling one check, and every one is caught. One
    first MISSED (a field length running past its row), because the
    trailing-bytes check also covers it; with both removed the test fails.
  - `tests/live/postgres` against Postgres 16, locally and in a new CI job
    on Linux x86_64 and arm64. It checks every getter's types round-trip
    (all 256 byte values, int8 extremes, exact floats, UTF-8), and that a
    parameter cannot be parsed as SQL. It checks real SQLSTATEs,
    transaction states, and that a timed-out `pg_sleep` is really
    cancelled on the server; the control, with no cancel, fails. It runs
    32 pooled queries concurrently on 8 connections, a 200k-row result
    and a 20MB value, and TLS with a verified certificate. By hand: a
    missing CA, a wrong hostname and a server without TLS are each
    refused, and md5 and cleartext servers log in.

  **Gap found:** a bare `[]` cannot be passed as an argument (an empty list
  literal needs a declared type and the parameter's is not used), hence
  `pg.no_args()`. Fixed separately in the compiler (#142).

  **Then, the rest of what was left out:**
  - **Streaming** (`stream` / `next_row` / `stream_close`): one row in
    memory at a time. `stream_close` cancels the query and waits for the
    cancel to be delivered before draining, so it can never land on a
    later query. 1M rows in 2.0s; 200k in 41MB of RSS. It does not stay
    flat beyond that (195MB at 1M, 555MB at 3M), and that turned out to be
    the runtime, not the driver: a ten-line loop of short-lived results
    grows the same way on macOS and Linux. Recorded in `todo.md`. The
    driver's own share was fixed: fresh lists per row, which the
    collector does not count, took 3M rows to 800MB.
  - **COPY** in both directions, one-call and streaming forms, with a
    COPY of the wrong direction refused and the connection kept.
  - **LISTEN/NOTIFY**: notifications queue whenever they arrive, even in
    the middle of a query's result. Reaching the deadline in
    `wait_notification` returns `none` without breaking the connection;
    a message cut off by that deadline is kept (`fill` now puts back what
    it read on any failure).
  - **Unix-domain sockets**, named by directory as libpq does, plus
    `net.dial_unix` / `net.listen_unix`.
  - **The connect deadline** now covers everything: `net.dial_until`
    (the DNS lookup is abandoned to the resolver thread on timeout, with
    ownership handed over atomically) and `net.tls_upgrade_until`.
    `net.dial` also now tries every resolved address, not just the first.

  **Another compiler bug, found running the driver on Linux:** GCC
  predefines `unix` and `linux` as `1`, so a slang variable named `unix`
  compiled on macOS and failed on Linux. `sanitize_ident` now mangles
  those and the libc macros (`errno`, `stdin`, …). Test:
  `tests/c_macro_names`.

  **Verified:** 15 fake-server scenarios (6 new) and 14 new controls. 12
  caught. "copy_out error lost" was a real gap, and a test was added. The
  pool-mode check is redundant with the status check (a busy connection
  has read no ReadyForQuery), so removing it alone changes nothing. The
  live test (11 checks) passes against Postgres 16 on macOS and, in a
  Linux container, over a Unix socket too. `tests/net_dial_until` covers
  the new `net` calls, including 3,000 dials racing short deadlines
  through the abandon path.

## 7. The ~5% SIGBUS under amplified preemption

- [ ] Find and fix it.

  Open the longest. `todo.md` records the signature, three explanations
  already tested and eliminated (do not re-chase them), and a concrete next
  step: poison the trampoline's resume-target slot on entry and validate
  it before the final `jmp`, turning corruption into a detection at the
  moment it happens.

## 8. Remote benchmarks

- [ ] Run the cross-language suite on a Linux host and record it in
  `bench/RESULTS.md` as its own run.

  `bench/run_remote.sh` is built, with a preflight that inspects the host
  before anything runs. It needs a host chosen deliberately: the suite
  saturates every core for minutes and binds ports, so it must not run on
  a machine serving anything.

## Notes

- Do not change `bench/http/main.sl` for perf experiments. Raw-best slang is `bench/http_opt/main.sl`; remasure with `./bench/run_http_opt.sh`.
- Do not start LLVM.
- Phase E claim requires p99 **and** RSS vs Go; RPS alone is not a win.
