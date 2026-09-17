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
  published release. Confirm the first run on `main` goes green.

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

- [ ] **arm64 — a port, not a CI fix.** arm64 does not build on ANY
  platform, Apple Silicon included: `runtime/sl_sched.c` has the async
  preemption trampoline (`sl_preempt_trampoline_entry`/`_end`) and the
  stack-growth trampoline (`sl_grower_trampoline`) only in x86_64
  assembly, so every program fails to link. It went unnoticed because
  every machine it has been built on is Intel. The signal handler in
  `sl_pool.c` already has arm64 code for macOS and Linux; only the
  assembly is missing.

  - The **grower trampoline** is small: x86_64's is three instructions.
  - The **preemption trampoline** is the hard part. After restoring every
    register, x86_64 resumes the interrupted code with `push`/`ret`,
    which needs no free register. arm64 has no equivalent: branching needs
    a register, and at an arbitrary interrupted instruction in C code any
    of them may be live (x16/x17 included, inside veneers). Candidate
    designs: resume through a second, synchronous signal whose handler
    restores the full context, so the kernel sets every register
    atomically; or a staged port that ships arm64 with async preemption
    off (loops already yield cooperatively at back-edges) and adds it
    afterwards.

  Add `ubuntu-24.04-arm` back to both CI matrices when it lands; GitHub's
  arm64 runners are native, where local Docker could only emulate.

## 2. OpenSSL discovery fallback

- [ ] When `pkg-config` is missing or cannot find OpenSSL, try `brew
  --prefix openssl` and the standard install locations before giving up;
  if nothing is found, say so in slang's own words.

  Found while verifying the v0.2.0 tarball: an https or `crypto` program
  fails with `'openssl/err.h' file not found` whenever `pkg-config` is not
  on PATH (`src/main.c`, the `tlsflags` block). On this machine Homebrew
  lives at `/usr/local/Homebrew/bin`, not `/usr/local/bin`, so even a
  sensible PATH misses it. It is the first error a new macOS user meets
  with https, and the raw C compiler error does not point at the cause.

## 3. `slangc test`

- [ ] A test runner in the compiler: discover test functions, run them,
  report pass/fail with locations.

  Every test in this repository is a shell script comparing stdout to an
  `expected.txt`. That works for the compiler's own suite; it is not
  something a team writing a service in slang can adopt. Design questions
  to settle first: how tests are marked, whether each runs in its own
  task (so one panic does not end the run), and how it fits `slang.project`.

## 4. Chunked request bodies in the `http` server

- [ ] Accept `Transfer-Encoding: chunked` on requests in `stdlib/http`.

  The server rejects them outright ("chunked encoding is not supported",
  `stdlib/http/http.sl`), yet common clients and proxies send them for
  streamed uploads. `httpc` already decodes chunked responses with bounded
  size lines and a total-size ceiling; the same limits apply here, where
  the input is even less trusted.

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
