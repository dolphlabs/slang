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
- [ ] Compiler: codegen emits stack maps at call sites for every
      generated function (the structural piece every bullet below
      depends on)
- [ ] Compiler: codegen emits stack maps at loop back-edges too, ahead
      of Tier 11's cooperative preemption needing them
- [ ] Runtime: replace every `GC_malloc`/collection call site with the
      new allocator; drop the libgc dependency once nothing calls it
- [ ] Gate before Tier 11 starts: the full existing test suite
      (`tests/*`, every tier 1-8) passes unchanged — observable
      behavior of every existing slang program must be identical; any
      difference is a bug in this tier, not an acceptable side effect

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
- [ ] Growable, GC-owned task stacks using Tier 10's stack maps +
      copying mechanism — start small (a few KB), grow on demand,
      never a fixed ceiling chosen up front
- [ ] A kqueue (macOS/BSD) / epoll (Linux) reactor behind one internal
      interface — `net.accept`/`net.recv`/`net.send`/`net.tls_*`
      register interest and park the calling task instead of blocking
      the OS thread; the reactor wakes the task when the fd is ready
- [ ] `time.sleep` parks the task with a timer instead of blocking the
      thread
- [ ] `chan_send`/`chan_recv` park the task on the channel's wait
      queue instead of blocking on a condvar
- [ ] `spawn` creates a scheduled task, not a `pthread_create` call
- [ ] Cooperative preemption v1: a checked "should yield" flag at
      every call and loop back-edge (using Tier 10's back-edge stack
      maps) — known, documented gap carried forward openly: a tight
      loop with no calls or back-edges (exactly what
      `demo/stress/stress.sl`'s `count_primes_range` is) cannot be
      preempted under this alone. Go shipped with exactly this
      limitation for ~10 years before adding signal-based async
      preemption in 1.14; that's an explicit stretch goal below, not a
      Tier 11 requirement
- [ ] Failure isolation (Tier 5) reimplemented for tasks instead of
      threads: a panicking task must not take down the process,
      matching today's `pthread_exit`-based behavior exactly in
      observable terms
- [ ] Signal handling (Tier 8) redesigned for far fewer real OS
      threads: `proc.shutdown_requested()`/`SIGTERM` delivery no
      longer has "every spawned thread blocks the signal, only main
      can get it" to lean on, since most concurrency is now logical
      tasks on a shared pool, not distinct OS threads — needs its own
      design pass, not a mechanical port
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