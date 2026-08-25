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

- [ ] `net` gains a TLS listener/dialer, built on the Tier 4 C interop
      against OpenSSL/BoringSSL (opaque `SSL*`/`SSL_CTX*` handles map
      naturally onto `rawptr`)
- [ ] Certificate/key loading (server + client)
- [ ] Example: the Tier 5 httpd successor served over HTTPS
- [ ] Tests: a real TLS handshake over loopback; negative tests for a
      bad/expired certificate

## Tier 7 — JSON / structured serialization

- [ ] Decode: `str`/`bytes` -> a slang value (needs a representation
      decision: a dynamic/`any`-like value type vs. decoding straight
      into a known struct shape)
- [ ] Encode: struct/map/list/scalar -> JSON `str`
- [ ] Tests: round-trip encode/decode, malformed-input handling

## Tier 8 — process lifecycle

- [ ] Signal handling (`SIGTERM`/`SIGINT`) for graceful shutdown
- [ ] Environment variable access
- [ ] Tests: signal delivered during an active `net` listener results
      in a clean shutdown (connections drained, not dropped)