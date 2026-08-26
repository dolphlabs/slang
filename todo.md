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