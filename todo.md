# slang roadmap — data types for server-side & network programming

Track progress top to bottom; tick items off as they land.

## Tier 1 — foundations

- [x] `bytes` type: length-prefixed, binary-safe byte sequences
  - [x] Lexer/parser: `bytes` type keyword
  - [x] Literals: `b"..."` byte-string syntax (binary-safe, no NUL termination)
  - [x] Runtime: `sl_bytes` struct { len, ptr } allocated via GC
  - [x] Builtins: `len(b)`, indexing `b[i]`, slicing `b[a..b]`
  - [x] Concatenation `+`, equality `==`/`!=`, printing
  - [x] Conversions: str <-> bytes, int -> bytes (LE/BE helpers)

- [x] Fixed-width integers & float
  - [x] Lexer/parser: `i8 i16 i32 i64 u8 u16 u32 u64 f32` type keywords
  - [x] Codegen: C type mapping (`int8_t` .. `uint64_t`, `float`)
  - [x] Type checker: widening rules within the int family, explicit-only narrowing
  - [x] Overflow/wrap semantics documented (wrap on cast)
  - [x] print/println + string interpolation support for all widths

- [x] Arrays / lists `[T]`
  - [x] Parser: `[T]` type syntax, `[a, b, c]` literals
  - [x] Runtime: growable array struct over GC memory
  - [x] Builtins: `len()`, push/pop, indexing with bounds checks
  - [x] Iteration: `for x in list { ... }`
  - [x] Slicing and concatenation

## Tier 2 — server workhorses

- [x] Maps `map[K]V`
  - [x] Parser: `map[K]V` type syntax, `{k: v}` literals (annotated & inferred)
  - [x] Runtime: open-addressing hash table over GC memory (FNV-1a hashing,
        insertion-order iteration, automatic growth at 75% load)
  - [x] Operations: get/set/delete (`m[k]`, `m[k] = v`), `len()`,
        `has(m, k)`, `del(m, k)`; missing-key reads are runtime errors
  - [x] Iteration: `for k, v in m { ... }` in insertion order
  - [x] Key types restricted to integers, `str`, `bool`; values may be any
        type incl. structs and lists

- [x] Structs
  - [x] Parser: `struct Name { field: T, ... }` declarations (top level only)
  - [x] Construction: `Name { field: value, ... }` literals (all fields
        required, no extras, types checked)
  - [x] Field access `p.x`, nested chains `r.tl.y`, mutation `p.x = v`
  - [x] Methods via `impl Name { fn ... }` blocks with `self` receiver;
        methods may return structs (chained construction works)
  - [x] Integration with packages (`pub struct`, qualified access,
        exported-method visibility) and lists of structs (`[Point]`)

## Tier 3 — reliability & differentiators

- [x] Option / Result types
  - [x] `Option[T]` with `some(v)` / `none`
  - [x] `Result[T, E]` with `ok(v)` / `err(e)`
  - [x] Null-coalescing operator `??`
  - [x] Pattern-friendly unwrapping (`guard let x = opt else { ... }`)

- [x] Time types
  - [x] `time.Duration` as first-class value
  - [x] Monotonic clock + wall-clock timestamps
  - [x] Timeout arithmetic for future net package

- [x] `net` standard package
  - [x] TCP listener / dialer built on bytes + fixed ints
  - [x] Non-blocking I/O primitives
  - [x] Example: minimal HTTP server in slang

## Tier 4 — C interop

C only. C++ libraries are out of scope for the compiler itself — the
documented path is to wrap them behind a hand-written `extern "C"`
shim and consume that shim as a C library, same as any other extern
fn below. No name-mangling/ABI work for C++ is planned.

- [x] `extern fn` declarations
  - [x] Parser: `extern fn name(params) -> ret;` (no body) at top level
  - [x] Codegen: emit a matching C prototype, call the real symbol
        directly — bypass slang's usual `sl_<pkg>_<name>` mangling
  - [x] Existing scalar types marshal for free: `int`/`i8..u64`/`f32`/
        `float`/`bool` already share their slang and C representations
  - [x] `str` passes as `const char *` directly (zero-cost: that is
        already `str`'s C representation). `bytes` does not
        auto-decay — instead a `bytes_ptr(b: bytes) -> rawptr` builtin
        exposes the raw buffer explicitly, paired with the existing
        `len(b)`; kept 1:1 slang-param-to-C-param rather than
        inventing implicit multi-arg expansion for one type
  - [x] extern signatures are type-checked at the boundary: only
        numeric types, `bool`, `str`, `bytes`, and `rawptr` may appear
        as a param/return type (GC'd containers rejected with a clear
        compile error, not a silent miscompile)

- [x] `rawptr` opaque pointer type
  - [x] Maps to `void *`; holds handles like `sqlite3*`/`FILE*`
  - [x] Passable and comparable (`== nullptr` / `!= nullptr`) only —
        no arithmetic, no field access, no dereference (rejected by
        the existing generic type checks, no special-casing needed)
  - [x] `nullptr` literal (reserved identifier, like `none`/`some`)
  - [x] Not GC-owned: a `rawptr` returned from an extern call is
        foreign memory; slang never frees it automatically
  - [ ] Stretch, not required for v1: `ptr[T]` typed pointers and
        `extern struct` layouts for passing C structs by value

- [x] Linking
  - [x] `link "name";` top-level directive (parsed like `import`),
        appends `-lname` to the final `cc` invocation
  - [x] Extra `-L`/`-I` search paths: rely on `LIBRARY_PATH`/`CPATH`
        env vars that `cc` already honors; no new slangc flag needed
        for v1
  - [x] Library name restricted to a conservative charset at parse
        time (letters, digits, `_-.+`) — it flows into a `system()`
        call in main.c, so this closes a command-injection vector for
        a hostile `link "...";` in third-party source

- [x] Safety notes (document, don't silently paper over)
  - [x] Boehm GC is conservative and generally sees pointers handed to
        C, but a slang value whose only reference lives in memory the
        GC can't scan could theoretically be collected while C still
        holds it — keep a live slang-side reference for the duration
        of any call that retains a pointer (documented in README)
  - [x] Callback function pointers (C calling back into slang) are
        out of scope for v1 (documented in README)

- [x] Tests
  - [x] A tiny hand-written C fixture library (`tests/ffi/lib.c`,
        built by `tests/run_tests.sh` into a static archive) exercising
        `extern fn` + `link` + `rawptr` + `bytes_ptr` + `nullptr` end
        to end
  - [x] Negative tests: undeclared extern symbol (link-time failure),
        `rawptr` arithmetic, `rawptr` field access, a non-FFI-safe
        extern param type, and a `link` name with shell metacharacters

## Tier 5 — concurrency & failure isolation

The core gap: `net.accept`/`net.recv`/`time.sleep` block the whole
process, so nothing today can serve more than one connection at a
time (`examples/httpd` handles connections one at a time in a `while
true` loop). Without this, `net` is a demo, not a server primitive.
Failure isolation is scoped in alongside it because it's the same
design problem: whatever concurrency unit gets picked needs an answer
for "one task hits a runtime error" that isn't "the whole process
exits" (`sl_rt_error` currently calls `exit(1)` unconditionally).

**Design note — the concurrency primitive changed mid-implementation.**
The plan going in was Go-style stackful coroutines (M:N scheduler,
epoll, per-task stacks). A spike proved that fundamentally
incompatible with Boehm GC as actually built: `GC_add_roots`-registered
coroutine stacks crashed inside `GC_mark_from` reproducibly, on two
independent context-switch implementations (`ucontext.h` and a
hand-written x86_64 switch), which ruled out a context-switching bug
as the cause. Root cause: a separately-`mmap`'d stack can numerically
land inside Boehm's own "plausible heap address" range, and a
stack-internal pointer (a saved frame pointer, a local's address) then
gets treated as pointing into a real heap page it never allocated —
`GC_add_roots` is documented "Wizards only" for exactly this kind of
misuse. Boehm's actually-supported mechanism for "another stack to
scan" is real thread registration, so the shipped design is real OS
threads (`GC_PTHREADS`/`GC_THREADS`, so `pthread_create` is
transparently GC-aware) instead. `net`/`time` needed no changes at
all — each spawned thread just blocks on the exact same syscalls
they already made. Ceiling: this scales to thousands of concurrent
connections, not Go's 100k+ goroutines; revisit only if real usage
shows that ceiling actually matters, since a future scheduler
wouldn't need to change the language surface below.

- [x] Concurrency primitive: `spawn f(args...);` — a statement, not
      an expression; args are evaluated eagerly in the spawning
      context (no closures to design around) and copied into a
      GC'd args struct read by a pthread trampoline
  - [x] `spawn` targets a plain top-level function or `extern fn`;
        rejected at compile time for builtins and methods (no self to
        thread through yet)
  - [x] `net`/`time` need zero changes: blocking syscalls on a real
        OS thread just block that thread, not the process
  - [x] `chan[T]` communication primitive: `make_chan(cap)`,
        `chan_send`, `chan_recv() -> opt[T]` (closed+drained -> `none`,
        reusing `opt[T]` instead of a second return-value convention),
        `chan_close`; backed by a mutex + two condvars, no per-element-
        type struct needed since only `chan_recv`'s `opt[T]` wrapping
        is type-specific

- [x] Failure isolation
  - [x] A `_Thread_local` flag sets `sl_rt_error` behavior: the main
        task's error still calls `exit(1)`; every other task's error
        prints `task panicked: ...` to stderr and calls `pthread_exit`
        (transparently GC-unregistering the thread) instead
  - [x] `exit(code)` unconditionally ends the whole process regardless
        of caller, matching its meaning everywhere else
  - [x] Closed the one gap that would have defeated isolation anyway:
        integer division/modulo by zero previously raised an
        uncatchable `SIGFPE`; now a checked runtime error like any
        other, so it isolates like one

- [x] Example: `examples/httpd` now spawns a task per accepted
      connection (`spawn serve(cfd);`); verified concurrent (a
      connection held open by `nc` does not stall a second, fast
      `curl` request — confirmed by wall-clock timing, not just that
      both eventually complete)

- [x] Tests: `tests/spawn` (deterministic spawn + channel rendezvous,
      no timing dependence — `chan_recv` blocking IS the
      synchronization point), `tests/spawn_isolation` (one spawned
      task deliberately panics; the other spawned tasks' results
      still arrive and the process exits 0), 5 negative tests (spawn
      on a builtin/method, `chan_send` type mismatch, untyped
      `make_chan`, send-on-closed-channel)

- [x] Bonus finds along the way, fixed as part of this tier's
      reliability work (both got their own regression tests):
  - [x] A real, pre-existing type-safety hole: a bare statement-level
        function call (`foo(bad_arg);`) never validated its
        arguments, because `ST_EXPR` codegen called `gen_expr`
        without ever calling `infer_type` first — every other
        statement kind (`let`, `return`, ...) already paired the two.
        A mismatched argument silently reinterpreted the wrong C
        value instead of being rejected.
  - [x] Integer division/modulo by zero (see failure isolation above)

## Tier 6 — TLS

- [x] `net` gains a TLS listener/dialer, built on OpenSSL (linked via
      `pkg-config openssl`, same pattern already used for libgc — and
      only when a program actually calls a `net.tls_*` function, so a
      plain-TCP `net` program stays dependency-free)
  - [x] `net.tls_server_ctx(cert_path, key_path)` / `net.tls_client_ctx(ca_path)`
        — reusable config, separate from the per-connection handle
        (`ca_path == ""` means the system trust store), matching
        OpenSSL's own `SSL_CTX` vs `SSL` split rather than hiding the
        config behind the listener fd
  - [x] `net.tls_accept(lfd, ctx)` / `net.tls_dial(host, port, ctx)` /
        `net.tls_send` / `net.tls_recv` / `net.tls_close` — a
        connection is an opaque `rawptr` (Tier 4's opaque-pointer type
        turned out to be exactly the right fit for `SSL*`)
  - [x] `native_check`/`native_gen` (the `time`/`net` dispatch table)
        refactored to a per-argument-kind table instead of scattered
        function-name/index special cases while adding these 7 new
        signatures — the old code had a dead, computed-and-discarded
        `want_fd` variable that this replaced
- [x] Certificate/key loading (server + client), strict verification
      by default: `SSL_VERIFY_PEER` plus `SSL_set1_host` for hostname
      checking, not just chain validation — verified with a real
      handshake where the chain is trusted but the hostname doesn't
      match, and confirmed that fails (this is the check most
      hand-rolled TLS clients silently skip)
- [x] Example: `examples/httpsd/` — the Tier 5 httpd successor's exact
      shape, served over HTTPS (self-signed cert committed as a test
      fixture); verified with a real `curl -k` request
- [x] Tests: `tests/tls/` — a real handshake over loopback (round-trip
      ping/pong through the encrypted connection), plus the two
      verification-failure cases that actually matter (untrusted CA;
      trusted CA but wrong hostname, isolated from DNS-resolution
      failure by connecting to `127.0.0.1` against a `CN=localhost`
      cert). Determinism verified over 10 repeated runs. Plus a
      negative test for a `net.tls_*` argument-type mismatch.
- [x] Validated with a standalone C spike before touching the compiler
      (same discipline as Tier 5's concurrency spike) — confirmed the
      exact API pattern (cert/key loading, `SSL_VERIFY_PEER`,
      `SSL_set1_host`) actually enforces correct semantics on this
      OpenSSL build before generating any code against it. Clean under
      ASan+UBSan on both the spike and the real generated programs.

## Tier 7 — JSON / structured serialization

- [x] Representation decision, put to the user explicitly (this was
      the one open question in this tier): typed struct decode/encode
      (chosen) vs. a dynamic JSON-value type navigated at runtime. Went
      with typed — `json.decode`'s target type is inferred from the
      binding's annotation via the same `cg->expect` mechanism
      `ok()`/`err()` already use for `result[T,E]`, and a
      decoder/encoder function is generated per distinct
      struct/opt/list/map[str,_] type reached, the same
      monomorphization pattern `opt[T]`/`result[T,E]` already use for
      their C typedefs. No new "any" type added to the language; a
      type mismatch is a `result` error, not a silent `null`.
  - [x] Codegen landed as its own `src/codegen/json.c` module rather
        than `NATIVE_SIGS` entries in `native.c` — `json.decode`/
        `json.encode` are generic over a target type, which the
        fixed-signature `NATIVE_SIGS` table has no way to express;
        this only became a clean addition because codegen.c had just
        been split from one 4200-line file into `src/codegen/*.c` by
        concern (the user's explicit ask, done right before this
        tier) — adding a generic-dispatch package to the old
        monolith would have meant editing the same giant file yet
        again
  - [x] Decode: parses into a generic internal tree first (`sl_json_val`
        — never exposed to slang), then a generated function walks it
        field-by-field against the target type. Nesting depth capped
        at 512 (recursive-descent parser + untrusted network input is
        exactly a stack-overflow DoS vector; empirically confirmed
        unbounded nesting crashes at depth ~100k on an 8MB stack,
        confirmed the cap rejects cleanly instead)
  - [x] Encode: struct/opt[T]/[T]/map[str,V]/scalar -> JSON `str`,
        recursively monomorphized the same way decode is
  - [x] Missing key on an `opt[T]` field defaults to `none`; on any
        other field type it's a decode error. Unknown keys ignored.
        Errors compose a path through nesting for free, as a side
        effect of each recursion level wrapping the error it received
        (`field 'addr': field 'city': expected a string, got a
        number`) — not designed in up front, found while writing the
        README's description of the error format and verified against
        the actual generated code
  - [x] `rawptr`/`chan[T]`/`result[T,E]`/non-`str`-keyed maps rejected
        at compile time with a clear error, not discovered at runtime
- [x] Parser validated as a standalone spike before touching the
      compiler (same discipline as Tiers 5 and 6): malformed input
      (unterminated strings, bad escapes, leading zeros, trailing
      garbage, control bytes), full `\uXXXX` including UTF-16
      surrogate pairs, and the nesting-depth DoS all verified clean
      under ASan+UBSan against the real embedded `sl_map`/`sl_arr`
      before being converted into the compiler's embedded-string-array
      format (round-trip verified byte-identical against the validated
      source)
- [x] Real bugs found and fixed along the way, each with a regression
      test:
  - [x] UBSan caught casting an out-of-range `double` (e.g. a JSON
        number like `99999999999999999999`) to `long long` before
        checking its magnitude — undefined behavior regardless of
        whether the result is later discarded. Fixed by checking
        magnitude first in all three integer-decode paths (`i8`..`i32`
        via a shared macro, `i64`, `u64`)
  - [x] Pre-existing, unrelated to JSON: a struct with an `opt[T]` (or
        `result[T,E]`) field failed to compile — `emit_struct_types`
        ran before `emit_opt_res_types`, so a struct body referencing
        `sl_opt_str` as a field type hit "unknown type name" (that
        typedef didn't exist yet). No existing test had a struct with
        an opt/result-typed field, so this had never been hit. Fixed
        by giving opt/result instantiations the same two-phase
        forward-declare-then-define treatment structs already have
        (`emit_opt_res_forward_decls`, emitted before struct bodies —
        safe because an opt/result field is always a pointer, so an
        incomplete type is all a struct body needs at that point)
  - [x] Pre-existing, unrelated to JSON: struct literal field values
        were inferred without pushing the field's type as `cg->expect`
        first (unlike function-call arguments, which already do this),
        so `none`/`some(..)`/`ok(..)`/`err(..)` as a struct field value
        couldn't self-infer. Fixed in both `infer.c` and `expr.c`
        (mirrors the existing function-argument `expect_push` pattern
        exactly); this is also what makes a self-referential struct
        via `opt[Self]` constructible as a literal, which the JSON
        test suite exercises directly to prove the compiler's own
        codec-registration doesn't infinite-loop on the cycle
- [x] Tests: `tests/json/` (struct/nested-struct/opt-present/
      opt-absent/list/map round-trips, self-referential struct via
      `opt[Self]`, malformed JSON, missing required field, wrong field
      type, extra fields tolerated, negative numbers, floats, list of
      structs, `bytes` input), `tests/fail_json_rawptr`,
      `tests/fail_json_map_key`, `tests/fail_json_untyped`, plus
      `tests/struct_field_expect` for the struct-literal inference fix
      on its own. All of the above also verified clean under ASan+UBSan
      against the actual compiled `.gen.c` output, not just the
      isolated runtime spike.

## Tier 8 — process lifecycle

- [x] Design decision, put to the user before writing code (this tier's
      one open question): slang's `net.accept()`/`recv()` are
      blocking and there's no `select`/multiplexing across sockets and
      channels yet, so "shut down cleanly on SIGTERM" needs a way to
      actually interrupt a blocked accept loop, not just a callback
      that never gets to run. Chose a flag (`proc.shutdown_requested()`)
      plus interrupting the blocking syscalls themselves (no
      `SA_RESTART`, so a blocked `accept()`/`recv()` returns an `err`
      result the instant a signal arrives) over delivering the signal
      as a `chan[i32]` — the channel approach doesn't by itself solve
      interrupting a blocked accept() either (still no select), so it
      would need the same syscall-interruption mechanism anyway for
      not much benefit over the flag.
  - [x] New `pkg_proc/` package (landed as a clean addition thanks to
        the codegen-folder-split work done just before this tier):
        `proc.shutdown_requested() -> bool`, `proc.getenv(name) ->
        opt[str]`, `proc.active_tasks() -> int` (see below)
  - [x] Real subtlety, caught before writing any codegen: POSIX does
        not guarantee *which* thread of a multithreaded process
        receives a process-directed signal like `SIGTERM` — if it
        lands on a spawned worker thread instead of the one blocked in
        `accept()`, the listener would never notice. Fixed by blocking
        `SIGTERM`/`SIGINT` in every `spawn`ed thread's signal mask from
        birth (inherited at `pthread_create` time from the spawning
        thread, which blocks-then-restores its own mask around the
        call) — gated on `proc` actually being imported, so a program
        that never imports it pays nothing extra per `spawn`. Only a
        thread that never blocks these signals can ever be chosen by
        the OS to run the handler, which in a slang program is only
        ever the main thread, since every other thread is spawned.
        Validated with a standalone C spike first (main thread blocked
        in `accept()`, a separate worker thread blocked in its own
        `recv()` with the signals pre-blocked exactly as planned, a
        real `kill -TERM` sent externally): the main thread's
        `accept()` reliably observed `EINTR` while the worker's own
        blocking call was completely unaffected, across 15+ repeated
        runs plus ASan/UBSan.
  - [x] Graceful *draining*, not just noticing the signal: a listener
        loop stopping accept doesn't help if `main()` returning kills
        every in-flight `spawn`ed connection immediately (a detached
        pthread doesn't get waited on when the process exits). Added
        `proc.active_tasks()`, a count of currently-running `spawn`ed
        tasks — incremented right before `pthread_create`, decremented
        once the task's function returns *or* panics (the existing
        `sl_rt_error`/`pthread_exit` failure-isolation path from Tier
        5 had to decrement it too, or a panicking task would leak the
        count forever). Deliberately just a poll-based counter, not a
        wait-with-timeout primitive of its own — composes with
        `time.sleep`, which already exists, instead of adding a second
        way to wait for something.
  - [x] `net`'s blocking calls needed zero changes to support the
        interruption: `accept()`/`recv()`/`connect()` already had no
        `EINTR` retry loop (only `send()` does, correctly, so an
        in-flight response finishes writing instead of getting cut off
        mid-send by the shutdown signal), so an interrupted syscall
        was already surfacing as a plain `result[_, str]` error.
  - [x] `examples/httpd/` and `examples/httpsd/` updated to actually
        use `proc.shutdown_requested()`/`active_tasks()` in their
        accept loops instead of `while true`, so the two canonical
        server examples demonstrate the real thing end to end (curl a
        request, send SIGTERM mid-flight, confirm the response still
        arrives in full and the process exits after draining) rather
        than just describing it.
- [x] Tests: `tests/proc/` (basics: initial flag/counter state,
      `active_tasks()` transitioning around a real `spawn`, `getenv`
      present/absent), `tests/proc_shutdown/` (the tier's actual ask:
      a real listener, a real `SIGTERM` sent to the process itself via
      `extern fn`'d libc `kill()`/`getpid()` — not `raise()`, which
      targets only the calling thread and wouldn't exercise the
      process-wide delivery path a real external `kill` uses — and a
      real in-flight connection proven to receive its full response
      after the signal arrives, not get dropped), plus
      `tests/fail_proc_getenv_argtype`. Stable across repeated runs
      (15+ for the signal-delivery mechanism alone) and clean under
      ASan+UBSan, including the panicking-spawned-task counter-leak
      check specifically.

## Tier 9 — bounded worker pool (stopgap, ships independently)

Context: an Aug 2026 stress test (`demo/stress_harness/`, see
`demo/README.md`'s "Stress test" section and the published "Arcade
Under Load" report) found a realistic mixed workload plateaus around
3,300-3,500 req/s, with the ceiling appearing already at 50 concurrent
clients. Root causes, all fixable without touching the concurrency
model at all: a hardcoded 64-entry `listen()` backlog, a fully serial
single-threaded accept loop, and the raw `pthread_create`/teardown
cost of one OS thread per connection — Tier 5's shipped `spawn` design,
correct for its scale but not free. This tier removes those three
specific costs while leaving Tier 5's real-OS-thread `spawn` semantics
completely unchanged. It is not the long-term fix — Tiers 10-11 are —
but it's cheap, safe to ship immediately, and buys runway while the
real rewrite is underway.

- [x] Larger `net.listen()` backlog: hardcoded `64` -> `1024` in
      `src/codegen/pkg_net/runtime_net.c:84`. Not made configurable via
      a new native fn — over-requesting is harmless (the OS silently
      clamps to its own `somaxconn`, confirmed 128 on macOS today, and
      a real number on a tuned Linux box), so there's no caller who
      needs a knob here yet; revisit only if one shows up. Full
      45-test suite reverified green after the change.
- [x] Parallelize the accept path: `N_ACCEPTORS` (4) spawned acceptor
      OS threads sharing one listening socket, chosen over
      `SO_REUSEPORT` — simpler and portable across macOS/Linux without
      relying on kernel-version-specific load-balancing behavior.
      Targeted the single-threaded accept loop in `demo/main.sl`'s
      main loop, confirmed as the actual bottleneck (server-side
      thread count never exceeded ~415 even at 2,000 offered clients —
      see the stress report). Each spawned acceptor is now off the
      main thread, so it needed the exact non-blocking-socket-plus-
      polling treatment `tls_accept_loop` already used for the same
      reason (`SIGTERM`/`SIGINT` blocked in every spawned thread's
      mask — Tier 8) — plain HTTP accept picked up that treatment for
      the first time here, since it used to run on the main thread
      specifically to get real signal interruption for free.
- [x] A bounded worker-pool dispatch model for accepted connections: a
      fixed pool of pre-spawned tasks (`WORKERS` env var, default 128
      per protocol) pulling accepted fds/TLS connections off a
      `chan[T]` queue, instead of `spawn`ing a brand-new thread per
      accepted connection.
  - [x] Decided: purely an internal detail of how `demo/main.sl`'s
        accept loop dispatches work, built entirely from `spawn` +
        `chan[T]` (a `chan[i32]` work queue for HTTP, `chan[rawptr]`
        for TLS since `net.tls_accept` hands back a connection handle,
        not a bare fd). `spawn`'s own semantics (Tier 5) are completely
        untouched — no new compiler primitive, no codegen change
        beyond the backlog constant. Shutdown draining stays exact:
        each acceptor signals a `done` channel on exit so the shutdown
        sequence knows precisely when it's safe to `chan_close` the
        work queue (unblocking every worker's `chan_recv` with `none`)
        without a race against an acceptor still trying to `chan_send`
        into an already-closed channel — verified directly: a
        `POST /api/stress/sleep` request in flight when `SIGTERM` was
        sent still completed in full (2.04s, 200 OK) before the
        process exited, matching the exact drain guarantee the demo
        already advertised under the old per-connection-spawn design.
- [x] Re-run `demo/stress_harness/` against this alone, before Tiers
      10-11 land — see `demo/README.md`'s "Stress test" section for
      the full before/after. Headline: total errors across the whole
      38-run matrix dropped from 3,823 to 1,885 while total requests
      served went *up* (1.53M -> 1.74M); the realistic mixed workload
      at high concurrency went from 2,736 req/s with 957 errors to
      3,572 req/s with zero, and the 60s soak went from 3,371 req/s
      with 38 errors to 3,899 req/s with zero.
  - [x] Caught and fixed mid-implementation, worth keeping as a
        cautionary note: the first pass reused `tls_accept_loop`'s
        original 50ms empty-poll backoff verbatim for the new
        HTTP/TLS acceptor loops. That interval was tuned for a
        lightly-loaded secondary shutdown-check path (Tier 8); reused
        as the *primary*, latency-critical accept path with only
        `N_ACCEPTORS` (4) threads covering all traffic, it added
        ~25-30ms to p50 latency across the board and made low-
        concurrency throughput measurably *worse* than the design it
        replaced (e.g. `counter_c25`: 9,960 -> 782 req/s) — caught
        only because the harness was re-run and compared, not assumed.
        Fixed by dropping the backoff to 1ms once these loops became
        performance-critical instead of periodic (`main.sl`'s
        `http_accept_loop`/`tls_accept_loop`), which restored
        sub-2ms latency at low concurrency. Real, measured cost of the
        fix: ~11-12% idle CPU from 8 acceptor threads (4 HTTP + 4 TLS)
        polling a non-blocking `accept()` every 1ms even with zero
        traffic — exactly the class of waste a real event-driven
        reactor (Tier 11) exists to eliminate; accepted here as the
        right tradeoff for a stopgap tier, not silently ignored.
  - [x] One known, honest limitation carried forward, not hidden: the
        deliberate breaking-point probe (`sleep`, holds a worker busy
        for 50ms, pushed to 1,200-2,000 offered clients) got *worse*
        on this metric specifically — errors rose from 32/176 to
        557/1,219. Root cause is different from before, though: with
        the default `WORKERS=128` per protocol, 128 workers each
        occupied for 50ms caps real throughput near 128/0.05s = 2,560
        req/s for this specific endpoint shape — genuine, correct
        backpressure from a bounded pool hitting real capacity, not
        the OS silently breaking down the way the original design did.
        Tunable via `WORKERS`; not chased further here since it's a
        sizing question, not a bug.

## Tier 10 — a precise, GC-integrated stack model (replacing Boehm)

**Design note.** Tier 5 already tried the obvious next step —
stackful coroutines on top of Boehm GC, unchanged — and it failed in a
specific, well-understood way: `GC_add_roots` on a separately-`mmap`'d
stack crashed `GC_mark_from` reproducibly, because Boehm has no
concept of "here is another stack, and here precisely are its live
pointers." That's not a Boehm bug, it's what a *conservative*
collector is: no notion of exact liveness, only "does this word's bit
pattern look plausible." Go's own M:N scheduler is inseparable from
Go's own GC for exactly this reason — the compiler emits exact stack
maps (which stack slots hold live pointers, at every safepoint), which
is what lets the collector scan a goroutine's stack precisely, and —
separately — lets a goroutine's stack be *copied* to grow it,
rewriting every pointer exactly instead of guessing. This tier builds
the slang equivalent of that foundation. It does not build a scheduler
or coroutines yet (Tier 11) — the deliverable here is a correct,
precise, single-threaded-semantics-unchanged garbage collector that
every existing slang program passes its full test suite against,
unmodified in observable behavior.

Scope deliberately narrower than Go's full runtime, on two specific
points, both permanent decisions, not "for now":
- **The general heap stays non-moving.** Slang already has `extern
  fn`/`rawptr` C interop (Tier 4) where C code can hold a raw pointer
  into slang-owned memory across a call boundary. A moving/compacting
  collector would silently invalidate that pointer the instant it
  relocated the object, with no way for the C side to know — strictly
  worse than Boehm's already-documented "keep a live slang-side
  reference" caveat, not better. Go makes the same call for the same
  reason (`cgo`/`unsafe.Pointer` stability: Go's heap is non-moving
  too, only goroutine stacks move). Only stacks move; nothing a
  `rawptr` could ever point to does.
- **Stop-the-world to start.** Concurrent tri-color marking with write
  barriers (what Go actually ships) is one of the hardest parts of
  Go's runtime, and it's a pause-time optimization, not a correctness
  requirement — Boehm is *also* stop-the-world today, so even a
  precise STW collector is a strict correctness and capability upgrade
  over what ships now. Concurrent marking is deferred to Tier 11's
  stretch goals, built only if a real workload's measured pause time
  demands it.

- [x] Spike (standalone C, no compiler involved — matching the
      discipline every prior tier used before generating real code
      against a new primitive): precise stack maps for a minimal
      function subset. Two safepoints over one hand-crafted frame,
      proving liveness is a per-program-point property (the same
      physical slot is correctly included in the map at safepoint 1
      and excluded at safepoint 2, once dead, even though its raw
      bytes are untouched) — plus a deliberate adversarial value
      (a plain integer crafted to numerically land inside a real heap
      allocation) that a naive whole-frame conservative scan
      demonstrably misidentifies as a pointer, while the map-driven
      scan never touches that offset at all, by construction. Clean
      under ASan+UBSan, zero warnings.
- [x] Spike: stack copying — grew a toy two-frame stack (an interior
      pointer from one frame into a local in the other, modeling
      `&local` passed to a callee — the real hazard, not just heap
      pointers) into a freshly allocated, larger buffer, then freed
      the old one outright. Verified: the interior pointer now points
      into the new stack at the translated offset and reads/writes
      correctly through it; both heap pointers in the frames are
      byte-identical, untouched; a second adversarial slot (a plain
      integer that happens to fall inside the old stack's address
      range) is copied byte-for-byte and never mistaken for a pointer
      needing translation. Clean under ASan+UBSan, zero warnings.
- [x] Spike: a non-moving, precise mark-sweep collector for the
      general heap, standalone (single-threaded, no coroutines,
      isolating GC correctness from stack-map and scheduler
      correctness). A 3-hop reachable chain survives a collection; an
      *unreachable reference cycle* (two objects pointing at each
      other, referenced from nowhere) is correctly collected — the
      case naive refcounting gets wrong and reachability-based
      mark-sweep gets right; every surviving object's address is
      byte-identical before and after the collection, making
      "the general heap stays non-moving" (required for `rawptr`/
      `extern fn` stability, see the design note above) a tested
      property instead of an assumption; a second collection with zero
      roots correctly reclaims everything remaining, proving mark bits
      are actually reset between cycles rather than leaking state
      forward. Clean under ASan+UBSan, zero warnings.
- [x] A real per-call-site liveness analysis pass integrated into the
      compiler (`src/codegen/liveness.c`/`.h`, ~950 lines), landed as a
      fully isolated, opt-in `--dump-liveness` CLI mode that never
      calls `codegen_program` and changes zero lines of any existing
      `gen_*` codegen file — the only change to existing files is two
      new nullable fields (`Expr.live_set`, `Stmt.backedge_live_set`)
      that every current consumer already safely ignores. Verified
      clean against the full 45-test suite (unaffected, since this
      mode is never invoked by default) plus a separate broad sweep:
      every real (non-`fail_*`) program under `tests/*/main.sl` and
      `demo/main.sl` compiles through `--dump-liveness` cleanly, every
      `fail_*` negative test is correctly rejected with the exact same
      diagnostic the real compiler gives, and output is byte-identical
      across repeated runs (determinism). Mirrors `gen_stmt`/`gen_stmts`/
      `gen_block`/`gen_expr`'s own recursion shape 1:1, computes exact
      live-GC-pointer-local sets via backward dataflow (`live_in(n) =
      uses(n) ∪ (live_out(n) \ defs(n))`), correctly tracks anonymous
      (non-variable) pending values across nested calls and field
      reads (the `foo(bar(), baz())`/`foo(p.child, bar())` cases from
      the plan), and reuses the real `var_push`/`var_find`/`infer_type`
      family throughout rather than reimplementing name resolution or
      type-checking. `type_is_gc_ptr()` landed first as its own
      reviewable primitive in `core.c`, composing the existing
      `is_arr`/`is_map`/`is_opt`/`is_result`/`is_chan`/`is_str`/
      `is_bytes`/`is_rawptr` predicates.
  - [x] Three real, caught-by-testing bugs along the way, each fixed
        before moving on (same "verify, don't assume" discipline the
        stress-test work and every prior tier used):
    - A first design draft kept its own separate nested-scope
          structure instead of the real `cg->vars`, on the theory that
          `cg->vars`'s "never truncated per block" behavior (confirmed
          real: no `ST_FOR`/`ST_FOR_IN`/guard-let case ever pops it)
          was something to work around. Wrong call: this language's
          *actual* scoping is function-flat, not block-nested, and a
          parallel scope model silently diverges from what real
          programs resolve to *and* leaves the real `infer_type`/
          `var_find` this pass depends on unable to see this pass's
          own declarations at all — surfaced as "undefined variable"
          errors on programs with no such variable anywhere in them
          (traced to two unrelated `.sl` files sharing a `/tmp`
          directory, which `load_packages` merges into one package —
          not a liveness bug itself, but the investigation that led to
          finding the real one). Fixed by deleting the parallel scope
          structure entirely and delegating name resolution to the
          real `var_push`/`var_find`, with a small index-aligned side
          table mapping `cg->vars` slots to this pass's own tracking
          identity (looked up fresh by index every call, never a
          cached `VarSym*`, since `var_push` can `xrealloc` the table
          out from under a held pointer).
    - The `foo(bar(), baz())` pending mechanism's first implementation
          had the direction backward: it let a call see its *own*
          pending marker (self-reference) and let a *later* sibling's
          marker leak into an *earlier* one instead of the reverse.
          Caught by hand-tracing a fixture against the analytically
          correct answer (`bar` should protect nothing, `baz` should
          protect `bar`'s not-yet-consumed result) rather than trusting
          the code's own output. Fixed with a two-phase algorithm: a
          forward pass snapshotting each child's earlier-sibling
          pending set, then the backward pass folding it in while
          explicitly stripping each child's own marker both before and
          after processing it.
    - Struct literal field values (`Wrapper{ outcome: err("boom") }`)
          need `cg->expect` pushed to the field's declared type before
          inference, exactly like `gen_structlit` does — missed
          entirely in the first pass, caught by the broad sweep against
          real tests (`tests/struct_field_expect` failed with "cannot
          infer the type of 'err()'" through this pass specifically,
          while compiling fine for real). Fixed by threading an
          optional per-child `expects` array through the shared
          children-processing helper, filled in properly for struct
          fields and call arguments (resolving the callee's parameter
          types the same way `gen_call` does) and left `NULL` for
          list/map literals, which the real codegen doesn't push
          per-element expectations for either.
  - [x] One documented, deliberately-not-fixed limitation: `ST_FOR`/
        `ST_FOR_IN` induction variables are declared only when this
        pass's backward walk reaches the loop statement itself, which
        happens *after* it has already processed everything textually
        after the loop (a consequence of walking backward while this
        language's variables, once declared, are visible for the rest
        of the function). A program that references a for-loop's
        variable from code after the loop ends (legal here, since nothing
        ever pops it) would get a loud `cg_error` from this pass
        instead of a resolved answer. Not hit by anything in `tests/`;
        would need a forward declaration pre-pass to fix properly, left
        for whoever needs it.
- [x] Sibling sub-expressions sequenced into named temporaries
      (`sequence_exprs`, `core.c`), closing the liveness pass's own
      Risk 1: codegen previously built several kinds of expressions by
      concatenating each child's generated text directly into one
      fused C expression (`name(a0, a1)`, `{el0, el1}`, `(a op b)`),
      and C leaves the relative evaluation order between unsequenced
      sub-expressions of a function call, an aggregate initializer, or
      a binary operator unspecified — invisible under Boehm's
      conservative scan, but exactly the assumption real stack-map
      emission (next) needs to actually be true, not just assumed.
      Fixed at 6 sites, cited directly against source: `gen_call`'s
      argument list, `gen_index`'s bytes/array-read cases, `gen_slice`'s
      start/end pair, `gen_list`'s element list, `gen_numeric_binary`/
      `gen_comparison`/`gen_string_concat`'s operand pair, and
      `ST_ASSIGN`'s bytes/array index-target cases. Confirmed already
      safe and deliberately left untouched: `gen_maplit`, `gen_structlit`,
      `ST_ASSIGN`'s map-target case, `gen_index`'s map-read case (all
      already sequence via real C statements), `&&`/`||` (C itself
      guarantees left-to-right short-circuit order), `??` (rhs only
      evaluates inside the resulting ternary, no sibling to race
      against), and `ST_SPAWN`'s arguments (already one statement per
      argument). A pure, mechanical, behavior-preserving transform —
      verified by generated-C inspection (`foo(bar(), baz())` now
      visibly evaluates `bar()` then `baz()` into named temps before
      the outer call, matching the liveness pass's assumed order
      exactly), the full 45-test suite passing unchanged, `demo/main.sl`
      rebuilt and smoke-tested end to end (struct field encoding, map
      read/write, arithmetic, JSON — all correct), and 3 representative
      programs (`spawn`, `json`, `structs`) byte-identical against
      `expected.txt` under ASan+UBSan.
- [x] Compiler: codegen emits stack maps at call sites for every
      generated function (the structural piece every bullet below
      depends on). Wired the liveness pass into the real compile
      path (`compute_liveness`, split out of `dump_liveness`,
      called once from `codegen_program` after the dry-run
      `gen_whole_program` pass -- package-level globals only exist
      once `emit_globals` has run, and a function referencing its own
      package's global needs that already resolvable) and made
      `gen_call` emit a real, per-call-site root list at every
      function call whose liveness-computed `live_set` is non-empty:
      `void *_sl_spN_roots[] = { ... }; sl_safepoint _sl_spN;
      sl_rt_safepoint_enter(&_sl_spN, _sl_spN_roots, K);` brackets the
      call, `sl_rt_safepoint_exit()` after capturing its result. The
      chain (`sl_safepoint`/`sl_rt_safepoint_top`, `runtime_core.c`)
      is a lexically-scoped "handle stack" (the same shape OCaml's C
      FFI `CAMLparam`/`CAMLlocal` uses), not a persistent per-function
      frame+bitmask table -- chosen because nothing scans it yet
      (`GC_malloc`/Boehm stays authoritative until the allocator-swap
      bullet below), so a per-call bracket is the simplest thing that
      is still real, correct, load-bearing infrastructure rather than
      a stub.
  - [x] `gen_call`'s own arguments are sequenced *incrementally* (one
        temp named+registered+ambient-pushed per argument, via a new
        shared `sequence_one`, as each argument is generated) instead
        of the sequencing fix's original batch-at-the-end shape:
        a pending sibling's temp has to exist before a later sibling
        that's itself a nested call is generated (`foo(bar(), baz())`
        -- `baz()`'s own bracket needs `bar()`'s temp).
  - [x] A new `cg->ambient_roots` stack closes a gap liveness.c's own
        pending tracking doesn't cover: it deliberately excludes
        bare-identifier siblings (a named local needs a stable slot,
        not an anonymous marker), which left nothing protecting one
        across a *later* sibling's own nested call in the same
        argument list (`combine(xs, baz())` -- `baz()` must see
        `xs`). Every sequenced GC-pointer value is pushed onto this
        shared, save/restored-per-group stack regardless of kind
        (strictly safer than mirroring liveness.c's exact bare-ident
        condition), so it composes correctly across nesting levels
        (`outer(x, combine(xs, baz()))` -- `baz()`'s bracket picks up
        both `x` and `xs`; `combine(...)`'s own bracket, built after
        popping its own pushes, still sees `x`).
  - [x] Four real bugs found and fixed along the way, each caught by
        direct testing (hand-built representative programs cross-
        checked against `--dump-liveness`), not assumed correct:
    - Placing `compute_liveness` before the dry-run `gen_whole_program`
          pass broke the real compiler (not just `--dump-liveness`)
          on any program with a package-level global referenced from
          its own package -- `demo/main.sl` itself, via `httpkit.sl`'s
          `CR`/`LF`/`SPACE` constants, since non-main-package globals
          only get `glob_push`-registered inside `emit_globals`.
          Fixed by moving the call to after the dry run.
    - `sequence_exprs`'s batch-at-the-end shape (the sequencing fix's
          original design, correct for pure evaluation-order) turned
          out to be actively wrong for pending-value registration: at
          every one of its other 6 call sites, ALL siblings were
          generated before ANY got a registered temp, so a nested
          call within a later sibling could never find an earlier
          one's temp -- caught by `[mk_a(), mk_b()]` (two calls in a
          list literal) crashing with "liveness-pending value has no
          registered temp". Fixed by replacing `sequence_exprs`
          (removed, now fully unused) with `sequence_one`, called once
          per sibling as it's generated, and converting every one of
          its former call sites (`gen_index`, `gen_slice`, `gen_list`,
          `gen_numeric_binary`/`gen_comparison`/`gen_string_concat`,
          `ST_ASSIGN`) plus `gen_call` itself to the same incremental
          shape.
    - `gen_index`/`ST_ASSIGN`'s index-target case hard-coded the
          sequenced index's C type to `int` for all three branches
          (map/bytes/array) when only bytes/array indices are
          actually always `int` -- a map's index is its *key* type,
          which can be `str` or anything else map-key-eligible.
          Caught by `tests/maps`/`tests/json` failing to compile
          ("incompatible pointer to integer conversion") once real
          sequencing touched the map case too. Fixed by determining
          the map branch's index ctype from `map_kv`'s key type
          (cast first, then sequence the already-casted value, same
          order `gen_call` uses) before ever assuming `int`.
    - `gen_maplit`/`gen_structlit` were left deliberately untouched by
          the original sequencing fix (their own sub-computations were
          already correctly *ordered* via real per-pair/per-field C
          statements) -- but Tier 10's liveness pass tracks their
          pairs/fields as pending siblings exactly like any other
          multi-child site (`process_children_reverse` is shared),
          and neither site registered anything, so a struct/map
          literal with 2+ GC-pointer-typed fields/pairs where one is
          itself a nested call crashed the same "no registered temp"
          way -- caught directly (`Wrapper { a: bar(), b: baz() }`,
          `{"k": combine(bar(), baz())}`). Compounded by their
          existing key/value temps (`_sl_k%d`/`_sl_v%d`) being scoped
          to a per-pair `{ ... }` block that closed immediately after
          its own `sl_map_put`, invisible to a later pair even once
          registered. Fixed by sequencing each field/pair value with
          `sequence_one` into the outer `({ ... })` scope instead
          (structlit gained a real per-field temp it never had
          before; maplit's per-pair block wrapper is gone, no longer
          needed once each value has its own uniquely-named temp).
    - `sequence_one` registered and ambient-pushed *every* value
          regardless of type, including plain scalars (int/float/
          bool) -- harmless in the sense that nothing scans
          `cg->ambient_roots` yet, but wrong on its face and caught by
          a real compiler warning on `demo/main.sl`'s own
          `RollResult` struct literal (mixed scalar and pointer
          fields): `-Wint-to-void-pointer-cast` on `(void
          *)_sl_seq1110_1` where the temp held a plain `int32_t`.
          Fixed by gating registration on `type_is_gc_ptr` of the
          value's own slang type (added as a `sequence_one`
          parameter) -- a scalar sibling still gets sequenced for
          evaluation order (Risk 1 applies to every type), just never
          registered or treated as a root candidate.
  - [x] Closed: `gen_maplit`/`gen_structlit`'s own container
        (`_sl_m`/`_sl_s`) is now pushed onto `cg->ambient_roots` right
        after allocation, before the per-pair/per-field loop's own
        `ambient_mark` is captured -- popped by that loop's existing
        restore, no separate bookkeeping needed. `gen_list` needs no
        equivalent: read directly, it builds each element into a
        plain non-GC C stack array and only calls `sl_arr_from` once,
        atomically, after every element already exists -- there's
        never a GC-allocated, partially-built object to protect.
  - [x] Closed: every `EX_CALL`-shaped codegen path now gets the same
        bracket `gen_call` already had. Extracted the bracket-building
        logic `gen_call`'s own tail had inline into a shared
        `wrap_safepoint` (`core.c`) -- confirmed a pure, behavior-
        preserving extraction (byte-identical generated C before/after
        for a representative program) -- and applied it to `gen_ctor`,
        the `none` literal, `gen_builtin_call` (every branch, void and
        non-void alike -- `wrap_safepoint`'s own NULL-result_ctype path
        already produces a valid void statement-expression, so no
        branch needed excluding), `json_call_gen`, and `native_gen`.
        `push`/`chan_send`/`has`/`del` (the only 2-argument builtins)
        and `native_gen`'s own N-arg loop got the same incremental
        `sequence_one` treatment `gen_call`'s arguments already have --
        `native_gen` had never been through the original sequencing
        fix at all (every native function with 2+ arguments had a
        latent Risk 1 gap since before Tier 10 started, found while
        doing this). Result-ctype computed via `infer_type(cg, e)`,
        guarded against two different void conventions found by
        reading the code directly: `infer_call`'s hand-written builtin
        cases return the string `"void"`, but `native_check`'s
        `NatSig->ret` is genuinely `NULL` for void (confirmed in
        `pkg_time/sigs.c`: `time.sleep`'s own table entry).
  - [x] Two more real bugs found and fixed along the way, both in code
        already shipped by earlier Tier 10 steps, neither previously
        exercised by `tests/` or `demo/main.sl`:
    - `??`'s lhs (`opt_bar() ?? baz()`, `deep(5) ?? none`) is
          sequenced into its own temp (`_sl_qN`) for evaluation order,
          same as always, but the temp was never registered --
          liveness.c doesn't special-case `??`, so a call on the right
          (now a real safepoint, e.g. `none` or a builtin) can have
          the left's pending marker in its own `live_set`, and
          `wrap_safepoint` had no registered temp to resolve it to.
          Caught directly: `println((deep(5) ?? none) ?? -1)` in
          `tests/opt` crashed with the same "no registered temp"
          error the very first version of this step's work also hit.
          Fixed by registering `_sl_qN` (and ambient-pushing it, since
          `lt` here is always opt/result -- always a GC pointer) right
          after it's created, explicitly popped before returning (its
          C-level scope is this expression's own block alone).
    - `sequence_one` registered and ambient-pushed *every* sequenced
          value regardless of type, including plain scalars, which
          would silently cast a bare `int`/`float`/`bool` to `(void*)`
          into some later sibling's root array -- wrong on its face,
          and caught by a real `-Wint-to-void-pointer-cast` warning on
          `demo/main.sl`'s own `RollResult` struct literal (mixed
          scalar and pointer fields). Fixed by gating registration on
          `type_is_gc_ptr` of the value's own slang type (a new
          `sequence_one` parameter, threaded through all ~20 call
          sites) -- a scalar sibling still gets sequenced for
          evaluation order (Risk 1 applies to every type), just never
          registered or treated as a root candidate.
  - [x] One critical bug found and fixed, **not** through static
        inspection or `--dump-liveness` -- only surfaced by actually
        running `demo/main.sl` under load and watching the server
        crash on a request *after* the one that triggered it: a
        `return` from inside a loop back-edge bracket (Tier 10's
        previous step) skips that bracket's own closing
        `sl_rt_safepoint_exit()`, entirely by construction -- this
        language has no `break`/`continue`, so `guard let ... else {
        return; }` (the idiomatic way to leave a loop early,
        pervasive throughout `demo/main.sl`) hits this on every use.
        The skipped `exit()` leaves `sl_rt_safepoint_top` (a
        `_Thread_local` chain) pointing at a now-stack-freed
        `sl_safepoint` the instant the containing function's C frame
        pops. Under the *old* one-thread-per-connection model this
        would have died with the thread, harmless; under Tier 9's
        worker pool, threads are long-lived and handle many requests
        in sequence with nothing ever resetting this chain between
        them, so the corruption survives to poison the *next*
        request's own safepoint operations on that same worker --
        reproduced exactly this way: `demo/main.sl`'s `http_worker`
        (`while true { ... guard let cfd = v else { return; } ... }`)
        answered one `/api/roll` correctly, then SEGV'd inside an
        unrelated `sl_rt_safepoint_exit()` call on the *next* request
        handled by that same worker thread (confirmed via ASan:
        `AddressSanitizer: SEGV ... in sl_rt_safepoint_exit`, called
        from `sl_demo_http_worker`, i.e. `http_worker` itself). Fixed
        with a new `cg->open_backedge_brackets` counter, incremented
        by `emit_backedge_enter` whenever it opens a bracket and
        decremented at each of its 5 call sites' own closing
        `exit()` -- `ST_RETURN` now emits that many
        `sl_rt_safepoint_exit()` calls immediately before the actual
        `return` (after any return value is fully evaluated, since
        its own evaluation may still need the enclosing brackets'
        protection), correctly unwinding every currently-open loop
        bracket regardless of nesting depth (`sl_rt_safepoint_exit`
        itself takes no argument, so N calls unwind N levels
        regardless of which loops they belonged to). Verified against
        the exact reproduction (ASan-clean, server survives 60+
        sequential requests including the original crashing sequence)
        plus a hand-built program calling nested-loop-with-early-
        return functions 20 times in a row on the same thread,
        confirming byte-identical, correct output every time -- no
        drift, no corruption, matching what worker-thread reuse
        actually exercises.
  - Verified: full 45-test suite unchanged; a `--dump-liveness`
        cross-check against generated C for representative programs
        (a builtin/ctor as a sibling of a nested call, all four
        2-argument builtins, a 2-argument native call, a struct/map
        literal with a nested 2-argument call inside one field/value)
        confirming every root array matches the liveness pass's own
        computed set; `demo/main.sl` rebuilt and load-tested end to
        end (60+ sequential requests across every route, including the
        stress endpoints, against both a plain and an ASan+UBSan
        build) -- the load test is what caught the `return`-unwind bug
        above; `-Wall -Wextra` clean generated C; ASan+UBSan clean and
        byte-identical against `expected.txt` on 11 representative
        tests (`maps`, `json`, `spawn`, `structs`, `opt`, `ints`,
        `bytes`, `lists`, `proc`, `nettest`, `time`) plus 9 hand-built
        programs covering every bug above; determinism (byte-identical
        repeated `--emit-c` runs).
- [x] Compiler: codegen emits stack maps at loop back-edges too, ahead
      of Tier 11's cooperative preemption needing them. Every loop kind
      (`ST_WHILE`, `ST_FOR`, `ST_FOR_IN`'s array/bytes/map variants,
      `stmt.c`) now wraps its own body with a call-site-shaped bracket
      (`sl_rt_safepoint_enter`/`exit`, re-executed every iteration) built
      from `Stmt.backedge_live_set` -- already computed by liveness.c's
      `solve_loop_fixpoint` and printed by `--dump-liveness`'s
      `*-BACKEDGE` lines, unconsumed by real codegen until now.
      Meaningfully simpler than the call-site work: `backedge_live_set`
      only ever holds *named* entries (`solve_loop_fixpoint` unions via
      `ls_union_named_into`, which never touches a `LiveSet`'s pending
      side -- pending is a purely intra-expression concept, meaningless
      across a control-flow edge), so every root is an already-declared,
      stably-addressable local -- no temp materialization, no
      incremental-registration ordering, no `ambient_roots` interaction
      needed, just `sanitize_ident` + `(void*)`, the same as `gen_call`'s
      own named entries. One new shared helper (`emit_backedge_enter`,
      local to `stmt.c`, not exposed elsewhere) covers all 5 call sites.
      Closes a real gap the call-site work left open: a loop-carried GC
      pointer the loop body's own calls never happen to touch directly
      (e.g. `println(i)` inside a loop, which is a builtin bypassing
      `gen_call`'s bracket entirely) had nothing protecting it during any
      iteration; now the loop's own bracket does, composing correctly
      with nested call-site brackets through the existing
      `sl_rt_safepoint_top` chain (verified with nested loops: an outer
      loop's own accumulator stays protected across an inner loop's
      entire run, including calls inside it).
  - [x] One real, pre-existing bug found and fixed along the way, in
        code untouched by either this step or the call-site step
        (confirmed via `git diff` against liveness.c: dates to the
        original liveness-pass commit): `ST_FOR_IN`'s bound variable(s)
        (`for x in xs` / `for k, v in m`) were never removed from any
        live set before escaping the loop's own liveness computation.
        `declare_var` only makes the name resolvable -- unlike
        `ST_ASSIGN`'s real-def case, nothing ever treated a for-in
        binding as a "definition" that kills prior liveness -- so
        whenever the loop body referenced its own bound variable(s)
        (virtually always) and the variable's type was GC-tracked
        (iterating an array of GC-pointer elements, or a map by key
        and/or value), the binding leaked backward into every earlier
        program point once the loop was textually last in its function
        (this language's declared-and-never-popped scoping keeps the
        `LiveVar` alive for the rest of the backward walk). Silent
        under `--dump-liveness` alone, but a hard compile error the
        moment a real bracket at an earlier call site tried to
        reference a C identifier (the bound variable) that doesn't
        exist yet at that point in the generated C -- caught directly
        (`for k, v in m` as a function's last statement, with an
        earlier call needing its own bracket). Fixed by capturing
        `declare_var`'s returned `LiveVar*` for each bound variable and
        explicitly `ls_remove_named`-ing both before they're stored
        into `backedge_live_set` or returned as the statement's own
        live_in.
  - Verified: full 45-test suite unchanged; `--dump-liveness`
        cross-checked against generated C for all 4 loop kinds
        (including the map for-in that exposed the bug above) plus
        nested loops (outer/inner accumulators both correctly
        protected, composing with calls inside the inner loop);
        `demo/main.sl` rebuilt and smoke-tested end to end, including
        `/api/stress/json`'s `for it in jr.items` (an array-of-struct
        for-in, exactly the shape the bug needed); ASan+UBSan clean and
        byte-identical against `expected.txt` on the same 9 tests as
        the call-site step plus 2 new hand-built loop programs;
        determinism.
- [x] Runtime: replace every `GC_malloc`/collection call site with a
      new precise, non-moving, cooperative stop-the-world mark-sweep
      collector (`src/codegen/runtime_gc.c`, ~410 lines emitted into
      every generated program); Boehm/libgc fully dropped (`gc.h`
      include, `GC_THREADS`/`GC_PTHREADS` defines, `GC_INIT()`, and the
      `-lgc`/pkg-config linking machinery in `main.c` all removed).
      `runtime_core.c` split into `RUNTIME[]` (prelude through the
      safepoint chain) and `RUNTIME_CONTAINERS[]` (chan/bytes/arr/map/
      strings, now allocating through `sl_gc_alloc`/`sl_gc_realloc`),
      emitted either side of `RUNTIME_GC[]` so the containers' `_new`
      functions can reference the collector they now depend on.
      `sl_arr`/`sl_map`/`sl_chan` each gained an `elem_is_ptr`/
      `key_is_ptr`+`val_is_ptr` field, set at construction from
      `type_is_gc_ptr` at every call site (stmt.c, expr.c, pkg_json/
      dispatch.c) — since every GC-tracked slang type is represented as
      exactly one C pointer (`ctype_of`), no per-element-type
      specialization is needed for tracing a container: an element slot
      is either "one pointer to mark" or "no pointer." Struct/opt/
      result/spawn-args-struct trace functions are generated by new
      `emit_struct_tracers`/`emit_opt_res_tracers`/inline-in-
      `emit_spawn_trampolines` functions (program.c), each conditioned
      on `struct_has_gc_fields`/`type_is_gc_ptr` so a type with no
      GC-pointer fields gets no tracer at all. `sl_json_val` (pkg_json's
      hand-rolled parse tree, not a slang-declared type) gets its own
      hand-written tracer in `pkg_json/runtime.c`, mirroring the
      built-in containers' pattern.
  - [x] A standalone, multi-threaded spike (rollout step 1 of the
        design plan; not part of the compiler, a throwaway scratch
        program) validated the collector's concurrency protocol before
        any of it touched real codegen — cooperative stop-the-world via
        the existing safepoint chain, a thread registry, a
        "blocked" flag so long-parked worker-pool threads (`accept()`/
        `recv()`) never stall a collection. **Five** distinct
        concurrency bugs were found and fixed there, each by a
        different technique: (1) a deadlock from the collector holding
        its own mutex across the entire quiescence wait, starving a
        mutator that needed the same mutex to finish an in-flight
        allocation — caught by a plain hang; (2) a data race from the
        naive fix for (1) (dropping the mutex for the whole wait and
        reading the live thread registry unsynchronized) — caught by
        TSan, not ASan/UBSan; (3) a one-shot-checkin race (losing the
        "become the collector" CAS in the narrow window before the
        winner's `stop_requested` store lands, then returning having
        neither acked nor waited) — found by reasoning through the
        exact interleaving; (4) a heap-use-after-free from a thread's
        `sl_gc_unregister_thread()` racing a brand-new collection's
        registry snapshot, then the OS tearing down that thread's own
        TLS out from under the collector — caught by ASan, traced
        straight to `_pthread_tsd_cleanup`; (5) a livelock from a
        thread's spin on the shared, reused `stop_requested` boolean
        missing a brief 0-then-1 transition across two back-to-back
        collections, leaving it permanently one cycle behind whatever a
        later collector was waiting on — the hardest to find, since
        nothing is corrupted or raced, the program is just
        intermittently (1-in-3 to 1-in-5 runs) stuck; needed a custom
        per-thread "last known state" tracer to actually see it.
  - [x] Wiring the collector into real codegen surfaced a **second,
        larger wave of bugs**, all in the existing root-coverage
        machinery from earlier Tier 10 steps — invisible until now
        because nothing walked the safepoint chain before this step, so
        every one of these was silently "fine" against Boehm's
        conservative scan:
    - A fundamental gap in `wrap_safepoint`'s bracket-building
          convention: several call sites (`push`, `chan_send`, `has`/
          `del` in expr.c; every multi-argument native call via
          `native_gen`, native.c; **`gen_call` itself**, the single
          most-used codegen path in the compiler) popped their
          `sequence_one`/`ambient_root_push` argument registrations
          *before* calling `wrap_safepoint`, following a documented
          convention ("arguments are the callee's concern from the
          moment they're passed") that is only true once control has
          actually *entered* the callee — this bracket's own entry
          checkin fires strictly *before* that, while a sequenced
          argument that isn't independently live afterward (e.g.
          `push(kept, Node{...})` where the fresh `Node` has no other
          reference) sat completely unrooted. Fixed by moving every
          affected pop to *after* the `wrap_safepoint` call.
    - A deeper version of the same gap at the liveness level:
          `live_expr`'s `EX_CALL` case captured `e->live_set` as a
          snapshot of `live_out` *before* processing the call's own
          arguments, deliberately excluding them — correct for what
          survives the call, but silently wrong for values whose *last
          use* is being passed as this call's own argument (a bare
          identifier, or a field-access base like `n2` in
          `to_str(n2.value)`, where `n2.value`'s own type is scalar so
          the pending-value mechanism never looks at `n2` at all).
          Fixed by using `process_children_reverse`'s own return value
          (which already threads named uses backward correctly) for
          `e->live_set`, instead of the pre-children snapshot.
    - `ST_FOR_IN`'s `backedge_live_set` never included the iterable
          itself (`xs` in `for x in xs`) — only the loop's *overall*
          live-in (protecting code textually before the loop) did,
          which doesn't help the loop's own per-iteration bracket. A
          collection at any iteration's own checkin could sweep the
          array/map/bytes being iterated the moment nothing else kept
          it alive afterward. Fixed by folding the iterable's own use
          into `backedge` too, mirroring the existing `joined`
          computation.
    - `chan_recv` (expr.c), `sl_net_recv` (pkg_net/runtime_net.c), and
          `sl_net_tls_recv` (pkg_net/runtime_tls.c) each allocate their
          result wrapper *before* calling a primitive that can block
          (`sl_chan_recv`, `recv()`, `SSL_read()`) — and a blocked
          thread is deliberately exempt from other threads' collection
          waits (correct: it can't be mutating the heap while blocked),
          which means a *concurrent* collection on another thread can
          run while this one sits blocked, sweeping the freshly
          allocated, not-yet-reachable wrapper out from under it. Not
          fixable via the caller's static roots array (built before the
          wrapper even exists) or via `sequence_one`/ambient (same
          reason) — each needed its own dedicated `sl_safepoint`
          entered right after allocation and held open across the
          blocking call specifically; for the two hand-written native
          functions, `sl_rt_safepoint_enter`/`exit` are just ordinary C
          functions, directly usable from hand-written runtime code the
          same way codegen-generated brackets use them.
    - All found via `tests/gc_stress/` (new), a stress test that keeps
          a 3000-element struct list rooted across ~600 rounds of
          deliberately-discarded churn (structs with string fields,
          string-keyed maps, a short-lived reference chain), run against
          the real, default 8MB threshold *and* against the same
          generated C with the threshold literally patched down to 512
          bytes–4KB to force many more real collections per run — the
          two must produce byte-identical output, since nothing about
          collection *frequency* should be observable. The `chan_recv`/
          `net_recv` class of bug additionally needed a concurrent
          spawn+chan program (`tests/spawn_isolation`) under the same
          lowered-threshold treatment, since it only manifests with a
          genuinely concurrent collection.
  - Verified: full 48-test suite unchanged at the real, default
        threshold; the entire suite (every non-`fail_*` test, `ffi`
        excluded — needs a separate fixture-library build step
        unrelated to this) re-run with each program's own generated C
        patched to a drastically lowered collection threshold (512
        bytes–4KB, forcing many real collections per run instead of
        typically zero), ASan+UBSan clean, byte-identical against each
        test's own `expected.txt` at both thresholds; TSan clean
        (including repeated runs) on every concurrency-relevant test
        (`spawn`, `spawn_isolation`, `proc`, `gc_stress`) at a lowered
        threshold, the first real exercise of the collector's STW
        protocol under genuine multi-thread contention through actual
        generated code, not just the standalone spike; `demo/main.sl`
        codegen (not full link/run — needs an external native library
        this environment doesn't have, unrelated to this tier)
        unaffected beyond the expected, benign increase in an existing,
        pre-existing `-Wunused-value` warning class (more calls now
        correctly receive real brackets); determinism (byte-identical
        repeated `--emit-c` runs); `-Wall -Wextra` clean generated C
        (only pre-existing "unused function" noise, proportional to
        which runtime helpers a given small test happens not to use).
      Deliberate simplification for v1, not an oversight: the
      collection threshold (`sl_gc_threshold`, runtime_gc.c) is a fixed
      8MB constant, not adaptive to live-set size — matches this tier's
      own "stop-the-world to start" design note (pause-time/heap-growth
      tuning is out of scope here, same as Tier 11's stretch goals for
      concurrent marking).
- [x] Gate before Tier 11 starts: the full existing test suite
      (`tests/*`, every tier 1-8) passes unchanged — observable
      behavior of every existing slang program is identical, verified
      at both the real default threshold and heavily-lowered thresholds
      forcing real collection pressure (see above) — any difference
      found along the way was treated as a bug in this tier and fixed,
      not accepted as a side effect.

## Tier 11 — the M:N scheduler & green threads

Builds on Tier 10's precise stack maps and copying mechanism to
finally deliver what Tier 5 set out to build: cheap, real, stackful
concurrency that doesn't cost an OS thread per task. This is the tier
that actually removes the ceiling `demo/stress_harness/` measured —
`spawn`, `net.*`, `time.sleep`, and `chan_send`/`chan_recv` all become
scheduler-aware instead of OS-thread-blocking, with zero change to how
slang code using them looks (no `async`/`await`, no closures, matching
Tier 5's original design goal exactly — Tier 10 was the missing
prerequisite, not a different plan).

- [ ] GMP-style scheduler (Go's own term for its model): logical tasks
      (G) run on a small, fixed pool of OS worker threads (M) sized to
      core count, each thread executing tasks off a work-stealing run
      queue
- [x] Growable, GC-owned task stacks using Tier 10's stack maps +
      copying mechanism — start small (a few KB), grow on demand,
      never a fixed ceiling chosen up front. Delivered as a standalone
      spike first (hand-rolled x86_64/arm64 context switch, grow-and-
      relocate across both the safepoint chain and the frame-pointer
      chain, single- and multi-threaded, plus a negative control
      proving the `_Thread_local` scratch-stack fix is load-bearing),
      then landed for real: `sl_task` (`runtime_core.c`), the context-
      switch asm + grow machinery (`runtime_sched.c`), the guard-margin
      check wired into `sl_rt_safepoint_enter`, and `main()`/every
      `spawn` trampoline (`program.c`) now actually running on a task-
      owned buffer (65536 bytes to start) instead of the OS-provided
      thread stack. Full design writeup, every finding (including two
      real bugs caught only by testing against actual generated code —
      not just the hand-written spike — and fixed: a switch-back
      argument-order bug causing SIGILL on every spawn-touching test,
      and a task-exit chain-rooting bug in the spike's own test
      harness), and full verification detail (48+1-test suite at both
      the normal and an artificially tiny GC threshold, a dedicated
      forced-growth test confirmed via direct instrumentation to
      exercise 8 real grows through real generated code, UBSan+TSan
      clean, ASan's known hand-rolled-switch incompatibility confirmed
      to carry over from the spike rather than newly found, determinism,
      warnings-clean generated C) live in
      `.claude/plans/synthetic-beaming-volcano.md`. Still exactly one
      task per OS thread — no scheduler yet, no work-stealing, no
      parking; that's the next bullet, not this one.
- [x] A kqueue (macOS/BSD) reactor behind one internal interface —
      `net.accept`/`net.recv`/`net.send`/`net.dial`/`net.close`/
      `net.nonblock` register interest and park the calling task
      instead of blocking the OS thread; the reactor wakes the task
      when the fd is ready. **epoll (Linux) is explicitly deferred to
      its own follow-on slice**, confirmed with the user up front
      (kqueue is the only backend testable on this machine) — behind
      the same internal `sl_reactor_wait` interface, so it's additive,
      not a rework. `net.tls_*` also stays deliberately unconverted
      this slice (see below) — `SSL_accept`/`SSL_connect`/`SSL_read`/
      `SSL_write`'s own `WANT_READ`/`WANT_WRITE` state machine is a
      materially different, harder problem deserving its own dedicated
      design pass. Landed alongside the signal-handling redesign below
      in the same slice, since the two are coupled: the redesign only
      becomes practical once `net.accept`/etc. themselves park instead
      of relying on a blocking-call-plus-`EINTR` to observe shutdown.
      A dedicated design review (mirroring every prior slice) found two
      more critical bugs beyond the nine already anticipated while
      designing: `sl_reactor_thread`'s per-event dispatch calling
      `sl_task_resume` unconditionally rather than only when the
      removal search actually found the task (a real double-resume
      when a shutdown event and a per-fd readiness event for the same
      task land in the same `kevent()` batch), and concurrent
      `EV_ADD`/`EV_ONESHOT` registration for the same `(fd, filter)` by
      two different tasks silently coalescing at the kernel level,
      permanently orphaning whichever registered first — fixed by
      scoping the design to exactly one waiter per `(fd, filter)`
      rather than building per-fd multiplexing, which required
      `demo/main.sl`'s own multi-acceptor pattern (a Tier-9 stopgap its
      own comments already called out for eventual removal) to
      collapse to one acceptor task per listener dispatching to the
      existing worker pool via `chan` — simpler, not just constrained,
      once a single parked `net.accept()` genuinely handles unlimited
      connections. Other findings: a self-found busy-spin bug (a
      shutdown-aware pre-check that made `net.send`'s must-keep-
      retrying contract spin at 100% CPU instead of genuinely parking,
      fixed with a per-call `abort_on_shutdown` parameter so
      `accept`/`recv`/`dial` abort but `send` never does); a
      cross-package compile-dependency problem (a program can import
      `proc` without `net`, so the signal thread can't reference the
      reactor's symbols directly — fixed with `sl_rt_shutdown_hook`, an
      always-defined core function pointer the reactor sets and the
      signal thread calls through unconditionally); every fd becoming
      non-blocking at the OS level unconditionally (a reactor
      fundamentally requires this), which broke `net.nonblock()`'s
      existing synchronous "would block" contract until fixed with a
      dedicated, self-locking `sl_net_user_nonblock` side-table
      tracking which fds the *user* explicitly opted into that
      contract for (own mutex, not `sl_gc_set`'s borrowed-lock
      discipline — real once fds are touched from genuinely concurrent
      worker threads). Full writeup of every finding lives in
      `.claude/plans/synthetic-beaming-volcano.md`. Verified: 49/49
      tests at both the normal and a lowered (512-byte) GC threshold,
      byte-identical; TSan+UBSan clean on `nettest` (8/8) and `proc`
      (6/6); `proc_shutdown` under TSan is flaky (~1 in 3 runs) but
      root-caused conclusively to a ThreadSanitizer-internal fault
      (crash inside TSan's own `StackDepotBase::Put`, never in
      application code, never a reported race), isolated by elimination
      against a minimal slang-independent repro and reproduced
      identically on an unrelated LLVM 22.1.3 toolchain — not a defect
      in this slice, see the plan file's Verification section for the
      full isolation writeup; the real, non-instrumented build is
      unaffected. A manual capacity proof (40 concurrent
      `net.accept`/`net.dial` pairs, 5x the 8-worker pool, staggered
      connect timing) completed 40/40 across 5 runs. A manual combined
      `time`+`net`+`proc` check confirmed a real `SIGTERM` promptly
      wakes a reactor-parked `net.accept()` via the dedicated signal
      thread while leaving a `chan`-parked and a `time.sleep`-parked
      task genuinely unaffected (matching pre-existing, unchanged
      behavior for those). Warnings-clean (checked against the
      pre-slice baseline — one pre-existing, unrelated
      `-Wunused-value` warning confirmed present at `HEAD` too, not
      newly introduced); determinism confirmed (byte-identical
      generated C across repeated compiles). A manual end-to-end check
      of `demo/main.sl` (rewritten per the single-acceptor scoping
      above) found and disclosed one more real, **pre-existing** gap:
      with TLS certs present, graceful shutdown hangs forever on an
      idle `tls_accept_loop`'s still-blocking `accept()`, because pool
      worker threads already had SIGTERM/SIGINT blocked
      (`sl_pool_start(1)`) before this slice touched anything —
      confirmed via `git show HEAD` this predates the slice entirely,
      not a regression from the signal-handling redesign below; folded
      into the case for TLS parking needing its own dedicated slice.
      With TLS disabled, the same shutdown drains cleanly and exits in
      ~200ms.
- [x] `time.sleep` parks the task with a timer instead of blocking the
      thread. Unlike `chan`, nothing else ever "satisfies" a sleeping
      task's wait — there's no other task to hand off to — so this
      built the one piece that was genuinely missing: a sorted-by-
      deadline wait list (`sl_time_sleepers`, reusing `sl_task.next`,
      package-local to `pkg_time/runtime.c`) plus one dedicated,
      `want_pkg(cg,"time")`-gated background thread (`sl_time_thread`)
      that actively notices deadlines passing and calls the fourth
      slice's own `sl_task_resume` on their behalf — no changes to the
      parking primitive itself, only a new caller, confirming it really
      is generic and reusable the way that slice's own writeup claimed.
      A dedicated design review (mirroring every prior slice) caught
      one critical, build-breaking bug before it ever compiled: the
      first-drafted `main()`-wiring line for starting the timer thread
      had no gate of its own, and would have called an undeclared
      function in the 46 of 50 tests that don't import `time` — fixed
      with a fresh `want_pkg(cg,"time")` check, mirroring the adjacent,
      already-correct `proc` signal-handler gate. The review also
      surfaced a real platform finding, confirmed empirically (this
      machine's `pthread` has no `pthread_condattr_setclock`, a
      Linux/glibc extension `pthread_cond_timedwait` needs for a
      monotonic-clock absolute deadline) — worked around by tracking
      deadlines in monotonic time throughout and never waiting longer
      than a 1-second chunk in one timed-wait call, bounding rather than
      eliminating the wall-clock-jump drift the old `nanosleep`-based
      implementation was fully immune to (an accepted, documented
      limitation, since no test asserts upper-bounded sleep timing).
      Two more real gaps were disclosed rather than fixed: a GC
      stop-the-world pause now delays every currently-due sleeper's
      wakeup by the pause length (the old per-thread `nanosleep` had no
      such coupling), and — more significant — parking `time.sleep` on
      `main()`'s own task can defeat `proc`'s SIGTERM/SIGINT delivery
      for a *later* blocking `net.*` call in the same program, since
      the "only main can receive these signals" invariant is enforced
      only at pool/timer-thread creation time, never re-established for
      main's original OS thread once its own task parks and that thread
      falls back to servicing the pool. This gap already existed
      structurally once `chan` could park (previous bullet) but
      `time.sleep` makes it far likelier to actually be hit; it's now a
      concrete constraint on the still-deferred signal-handling redesign
      below (derive "is this main" from `sl_task.is_main`, not OS-thread
      identity). Full writeup of every finding lives in
      `.claude/plans/synthetic-beaming-volcano.md`. Verified: 49/49
      tests at both the normal and a lowered GC threshold; TSan clean
      (0 races) on `time`/`proc`/`proc_shutdown`'s real generated code
      — the latter, importing both `time` and `proc`, doubling as the
      combined-import signal-delivery check; a manual check
      (`scratchpad/time_check/main.sl`) proving 16 tasks sleeping 500ms
      *simultaneously* on the 8-worker pool complete in ~507ms, not the
      ~1000ms two serialized batches would produce — the falsifiable
      proof of genuine concurrent capacity. A dedicated spike
      (`scratchpad/poolspike/time_park.c`) proved the sorted-list +
      timer-thread mechanism itself, including a test that inserts an
      earlier deadline while the timer thread is already mid-wait on a
      stale, longer one and confirms it re-arms correctly rather than
      waiting out the original chunk.
- [x] `chan_send`/`chan_recv` park the task on the channel's wait
      queue instead of blocking on a condvar. Built the actual generic
      parking primitive Tier 11 needed all along: `sl_task_park`/
      `sl_task_resume` (`runtime_pool.c`) plus a new global,
      `sl_gc_mu`-guarded `sl_parked_tasks` GC registry (`runtime_core.c`)
      that every future parking site (`net`/`time`, still unchecked
      below) will reuse as-is. `sl_chan`'s two condvars
      (`not_empty`/`not_full`) are gone, replaced by
      `send_waiters`/`recv_waiters` — plain per-channel wait lists built
      on `sl_task.next`. A dedicated design review (mirroring every
      prior slice) found two more critical bugs beyond the four already
      anticipated while designing: a lost-wakeup race (a parked task
      cannot use a condvar-style "unlock, then block" sequence — the
      mutex it parked on must stay locked across the context switch,
      released only by the worker loop *after* the switch safely
      completes, or a concurrent resume can switch into a not-yet-valid
      `rsp`), and a real deadlock in `main()`'s own top-level code the
      moment its own blocking `chan_recv` call could park — exactly
      what `tests/spawn`'s own top-level `chan_recv` loop already does.
      Fixing that meant `main()`'s task itself became heap-allocated
      (like `sl_task_submit` already does for every spawned task,
      instead of repurposing the per-thread idle-sentinel struct in
      place) and gained a shared `sl_worker_after_switch`/
      `sl_worker_run_loop` dispatch used by *both* the real pool workers
      and main's own one-off switch-in — once main's own task parks,
      its OS thread simply joins the pool from that point on. That in
      turn forced `sl_rt_is_main_thread` (previously `_Thread_local`,
      safe only as long as main's OS thread could never run any task
      but its own) to move onto the task itself
      (`sl_task.is_main`), since a thread that's absorbed into the pool
      can now run arbitrary other spawned tasks too. Landed in stages
      (generic scheduler pieces first, as exercised-but-uncalled code;
      real `chan` behavior last), each gated on the full suite. Full
      writeup of every finding lives in
      `.claude/plans/synthetic-beaming-volcano.md`. Verified: 49/49
      tests at both the normal and a lowered GC threshold; TSan clean
      (0 races) on `spawn`/`spawn_isolation`'s real generated code,
      byte-identical output — both now genuinely exercise parking via
      main's own top-level `chan_recv` loop, not just the old
      condvar-blocking path; a manual check
      (`scratchpad/chan_check/main.sl`) proving 16 tasks can be parked
      *simultaneously* on `chan_recv` against the 8-worker pool — the
      exact rendezvous scenario that deadlocked when tried against the
      third slice (chan still blocked the OS thread back then), now the
      direct, falsifiable proof of genuine concurrent capacity, not
      just queue throughput. A dedicated spike
      (`scratchpad/poolspike/chan_park.c`) proved the lost-wakeup race
      and the main-parks-first deadlock are both real and both fixed,
      via two regression tests that deliberately toggle each fix off
      and confirm the bug reproduces (a crash and a wrong exit path,
      respectively, each bounded by a forked+`alarm()`-bounded child so
      neither risks hanging the test binary itself) before confirming
      the fixed path is clean across thousands of iterations.
- [x] `spawn` creates a scheduled task, not a `pthread_create` call.
      `stmt.c`'s `ST_SPAWN` now calls `sl_task_submit` (the shared run
      queue from the scheduler-foundation bullet above) instead of
      `pthread_create`; `main()` starts a fixed worker pool once
      (`sl_pool_start`, floored at 8 workers — see below for why) before
      any user code runs, instead of one OS thread per spawn. The
      now-dead per-spawn pthread trampoline and its
      `pthread_cleanup_push` GC-registry cleanup handler were deleted
      rather than left inert. Landed only after a dedicated design
      review found four real issues up front, and — during the spike
      de-risking pass that followed — a fifth, deeper concurrency bug
      the review itself had missed: a task dequeued from the run queue
      could have its args struct swept by a real collection before it
      ever ran, in two independent ways (a "popped but not yet
      assigned" window, and a subtler wake-from-idle race where a
      worker could dequeue and assign a task while a collection's mark
      phase had already scanned its slot as idle). The second was found
      only empirically, via a dedicated stress test and a from-scratch
      sequence-numbered diagnostic build (plain concurrent-stderr file
      order was not reliable enough to reconstruct true causal
      ordering), at roughly a 1-in-30-to-100 failure rate with only the
      first fix in place. Full writeup of every finding and both fixes
      lives in `.claude/plans/synthetic-beaming-volcano.md`. Verified:
      49/49 tests at both the normal and a lowered GC threshold; TSan
      clean (0 races) on `spawn`/`spawn_isolation`/`proc_shutdown`'s
      real generated code across repeated runs, byte-identical output;
      warnings-clean generated C (checked against a pre-slice
      baseline); a manual check that 16 genuinely blocking tasks
      complete correctly against the 8-worker pool. The pool floor
      (8, not a real core-count-driven size) is an explicit,
      flagged stopgap, not a considered capacity choice —
      `tests/proc_shutdown` already has two simultaneously-blocking
      spawned tasks, and `chan`/`net`/`time` still block the OS thread
      they run on until the next three (unchecked) bullets land, so a
      low floor is a live risk today, not theoretical. No work-stealing
      (single shared queue, not per-worker deques) — the top-level
      GMP-style-scheduler bullet stays unchecked until that and the
      parking bullets below land too.
- [ ] Cooperative preemption v1: a checked "should yield" flag at
      every call and loop back-edge (using Tier 10's back-edge stack
      maps) — known, documented gap carried forward openly: a tight
      loop with no calls or back-edges (exactly what
      `demo/stress/stress.sl`'s `count_primes_range` is) cannot be
      preempted under this alone. Go shipped with exactly this
      limitation for ~10 years before adding signal-based async
      preemption in 1.14; that's an explicit stretch goal below, not a
      Tier 11 requirement
- [x] Failure isolation (Tier 5) reimplemented for tasks instead of
      threads: a panicking task must not take down the process,
      matching today's `pthread_exit`-based behavior exactly in
      observable terms. `sl_rt_error`'s non-main-thread path no longer
      calls `pthread_exit` (which would permanently shrink the pool by
      one worker per panic, eventually draining it to zero under the
      new pooled `spawn` above) — it abandons the panicking task by
      context-switching back to the worker loop instead, exactly the
      way a normal task completion already does, so the OS thread
      keeps running future queued tasks. `tests/spawn_isolation` passes
      unchanged (TSan clean, byte-identical output) confirming a panic
      still isolates correctly; a dedicated spike test panics from
      three frames of call-stack depth, mixed with normal-completing
      tasks on a pool smaller than the task count, confirming the pool
      never shrinks. Two genuine can't-happen guard sites (a task
      resuming after its own switch-back — impossible by construction,
      but the fallback that used to call `sl_rt_error` would otherwise
      recursively re-enter the panic machinery it's already inside) now
      `abort()` directly instead.
- [x] Signal handling (Tier 8) redesigned for far fewer real OS
      threads: replaced the old `sigaction`-installed handler (which
      depended on leaving exactly one specific OS thread — the
      *original* main thread — unblocked, an invariant the fourth/
      fifth slices' own parking already broke, since main's task can
      migrate to any pool worker) with a dedicated `sigwait()`-based
      signal thread that owns `SIGTERM`/`SIGINT` delivery regardless of
      which OS thread happens to be running which task. `main()`
      blocks both signals once, globally, before any other thread is
      ever created, so every subsequently-created thread (pool
      workers, the timer thread, the reactor thread, the signal thread
      itself) inherits the blocked mask automatically — collapsing the
      old per-subsystem `block_signals` parameter threaded through
      `sl_pool_start`/`sl_time_start` into one place.
      `sl_rt_shutdown_flag` also drops its old `volatile sig_atomic_t`
      type for a real `_Atomic int` with proper memory-order semantics,
      since `sigwait`-based delivery runs as ordinary code in a normal
      thread, not inside an actual async-signal-handler context, so the
      old async-signal-safety constraint no longer applies. Landed in
      the same slice as the kqueue reactor above, since the two are
      genuinely coupled — this redesign only becomes practical once
      `net.accept`/etc. themselves park instead of relying on a
      blocking-call-plus-`EINTR` race to observe shutdown; see that
      bullet for the full design-review writeup (the two critical bugs,
      the busy-spin fix, the cross-package `sl_rt_shutdown_hook`
      indirection) and the verification detail (49/49 tests at both GC
      thresholds; TSan clean on `proc` real generated code, with
      `proc_shutdown`'s TSan flakiness root-caused to a
      ThreadSanitizer-internal fault, not a runtime bug; a manual
      combined `time`+`net`+`proc` check proving a real `SIGTERM`
      wakes a reactor-parked task promptly while leaving `chan`/
      `time.sleep`-parked tasks genuinely unaffected). One real,
      pre-existing gap surfaced (not caused) by this slice's own manual
      `demo/main.sl` verification: TLS's still-unconverted, genuinely
      blocking `accept()` (`net.tls_*`, deliberately out of scope this
      slice) never gets `EINTR` when running on a pool worker thread,
      since pool workers already had these signals blocked before this
      redesign touched anything (confirmed via `git show HEAD`) — not
      a regression, but one more concrete reason TLS parking needs its
      own dedicated design pass.
- [ ] Tests: every Tier 5/8 test (`tests/spawn`,
      `tests/spawn_isolation`, `tests/proc_shutdown`, the
      `examples/httpd`/`examples/httpsd` signal-drain checks) passes
      unchanged in observable behavior, now running on the new
      scheduler
- [ ] Acceptance test: re-run `demo/stress_harness/` against the new
      runtime, same methodology, directly against the numbers already
      in the published stress report — this is the concrete,
      falsifiable "did this work," not a vibe check

**Stretch, explicitly deferred, not required to call Tier 11 done:**
- [ ] Async/signal-based preemption (Go 1.14's mechanism) — only if
      real workloads show the cooperative-only gap above actually
      matters in practice
- [ ] Concurrent marking + write barriers in Tier 10's collector, if
      measured STW pause time under real load demands it
- [ ] `io_uring` reactor backend for Linux, behind the same interface
      as the kqueue/epoll backend, if warranted