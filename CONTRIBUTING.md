# Contributing to slang

Thank you for wanting to help. This file is what you need to build the
compiler, run its tests, and get a change merged.

By contributing you agree that your contribution is licensed under the
[MIT licence](LICENSE), like the rest of the project. Please sign your commits
off (`git commit -s`), which adds a `Signed-off-by:` line certifying the
[Developer Certificate of Origin](https://developercertificate.org/). Nothing
checks this automatically yet; we ask that you do it anyway.

Everyone taking part is expected to follow the [Code of
Conduct](CODE_OF_CONDUCT.md). To report a security problem, read
[SECURITY.md](SECURITY.md) and do not open a public issue.

## Build and test

You need a C compiler and `make`. Some packages need system libraries:

| Needed for | Library |
|---|---|
| `net` over TLS, `crypto`, `httpc` over https | OpenSSL |
| `sql` | SQLite |
| `compress`, and gzip in `httpc` | zlib |

On Debian or Ubuntu:

```sh
sudo apt install build-essential libssl-dev libsqlite3-dev zlib1g-dev git python3
```

On macOS, install OpenSSL with `brew install openssl`; the Xcode command-line
tools provide the rest. `python3` is used by a few tests and by the docs
build.

```sh
make            # build ./slangc against this working tree
make test       # the whole suite
make docs       # rebuild the documentation site
```

**Run one `make test` at a time.** Every run writes `main.gen.c` in the
working directory, so two at once corrupt each other and produce failures that
are not real.

A test that fails on its own can be run directly:

```sh
./slangc tests/<name>/main.sl --run
```

## What a change needs

- **A test.** A positive test is `tests/<name>/main.sl` with an
  `expected.txt` of its exact output (and a `stdin.txt` if it reads input). A
  test that must be *rejected* is `tests/fail_<name>/main.sl`, and it must fail
  to compile. Each directory is one package, so a test that needs several
  programs gets a subdirectory each (see `tests/io_tty`).
- **For a bug fix, a test that fails without the fix.** Show it: run the test
  against the code before your change and say what it printed. A regression
  test that passes on the broken code proves nothing.
- **Memory-safety changes get GC stress.** Add the test to the
  `SLANG_GC_THRESHOLD_KB=16` list in `tests/run_tests.sh`, which forces a
  collection every few allocations and is what catches an unrooted value.
- **Generated C stays warning-free.** `make test` checks it, under the
  platform's own compiler.
- **Docs.** The README is the source of the documentation site. After changing
  the README, a `pub` declaration in `stdlib/`, a native package's signature
  table, or `bench/RESULTS.md`, run `make docs` and commit the result: `docs/`
  is tracked. If two branches conflict in `docs/`, regenerate it; do not merge
  it by hand.

Changes to the runtime, the scheduler, `net` or the collector should be run on
Linux as well as macOS. Continuous integration runs on merges to `main` and on
manual dispatch, which runs the workflow on any branch, native linux-arm64
included: `gh workflow run ci.yml --ref <branch>` (on a fork, in your own
Actions). Without that, run the suite yourself, for instance in an Ubuntu
24.04 container built from `git ls-files` (a macOS-built `slangc` or
`tests/runtime/test_gc` copied into it will not run).

## Workflow

- `main` is the release branch. Work is integrated on `dev`.
- **Branch each change from the current `dev`, one branch per task, and open the
  pull request against `dev`.** Do not build a branch on top of another
  unmerged one: if the first changes, the second is stranded.
- Write the pull request description for someone who has not seen the
  conversation: what changed and why, the evidence (what failed before, what
  passes now), where you ran the suite, and anything you did not do.

## If you touch `runtime/`

The runtime is C that `slangc` splices into every program it compiles, and it
runs on green threads with unusual constraints. Get these wrong and the failure
is rare and hard to reproduce.

- Tasks run on **8 KB stacks** that grow only at slang checkpoints, which C code
  does not have. No large stack arrays and no deep recursion.
- **Bracket every libc call** that can allocate or take a lock (`malloc`,
  `free`, `stdio`, `getaddrinfo`, and so on) with `sl_rt_preempt_disable()` and
  `sl_rt_preempt_enable()`. A task can be preempted asynchronously between any
  two instructions.
- **Never allocate GC memory while holding a mutex.** A collector waiting for
  your thread to reach a safepoint while you wait for the collector is a
  deadlock.
- The runtime files are joined into **one translation unit**, so their order
  matters (`sl_net.c` comes before `sl_io.c`, which uses its reactor).
- **Never read a `_Thread_local` bare from code that can run on a task.** A
  task moves between OS threads at every park, yield and preemption, and the
  C compiler keeps a thread-local's address across those calls (GCC on
  aarch64 caches the thread pointer; clang on Darwin, the TLV address), so a
  bare read uses another worker's state. That holds even inside a preemption
  bracket: the bracket stops the task moving, not the compiler reusing an
  address computed before it. Read the current task with `SL_RT_TLS_CUR()`
  inside a bracket or `sl_rt_cur()` outside one, and any other thread-local
  through its `SL_RT_TLS_ADDR_FN` accessor inside a bracket (see that macro in
  `runtime/sl_core.c`). Bare reads are for code that only runs on a thread's
  own stack: the worker loop, `sl_worker_after_switch`, signal handlers.

The README's *How it works* and *Memory management* sections explain why.
