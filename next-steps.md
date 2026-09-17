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

- [ ] Let `impl T { fn get }` coexist with a package-level `fn get`.

  Methods are emitted under the same C symbol as package functions
  (`mangle_func(pkg, name)`), and registered in the same namespace, so the
  two collide with "redefinition of function". This is why `httpc` exposes
  `client_get(c, ...)` rather than `c.get(...)`. Touches the redefinition
  check in `sig_register_raw`, the name lookup in `sig_find_in`, the
  prototype and definition emitters in `program.c`, and the method call
  site in `expr.c`. Once fixed, `httpc` can gain method forms.

## 6. Postgres driver

- [ ] A networked database driver, speaking the Postgres wire protocol
  over `net`, with errors through the same `result[_, str]` story as `sql`.

  `sql` is SQLite only, and most server applications need a networked
  database. Unlike SQLite this is a protocol, not a C library call, so it
  can run on the scheduler without blocking a worker.

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
