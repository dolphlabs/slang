# Tooling

> Testing, race detection, profiling, task dumps, LSP and CLI tools.

## Tooling

slang ships its everyday engineering tools either directly inside `slangc`
and the standard library (`runtime`) or as companion open-source tools in
the ecosystem, so teams can test, race-check, profile, format, and inspect
production binaries without wiring together external toolchains.

| Tool | Role | Entry point |
|---|---|---|
| Compiler, deps & docs | Compile to C/native binary, fetch `pkg` pins, query stdlib signatures, JSON diagnostics | `slangc` (`new`, `get`, `doc`, `--run`, `--dev`, `--json`) |
| Test runner | Package-level task-isolated tests with filtering and verbose timing | `slangc test` (`-v`, `--run <pat>`, `--keep`) |
| Data-race detector | ThreadSanitizer across M:N `spawn` tasks and OS workers | `slangc test --race`, `slangc --race`, `SLANG_RACE=1` |
| Profiler & task dumps | Live green-task snapshot (`SIGQUIT`), 100 Hz CPU profiler, sampled allocation/heap profiler, `/debug/pprof/` text handler | `import "runtime"`, `kill -QUIT <pid>` |
| Runtime & GC tuning | Exit GC/scheduler stats, minor write-barrier verifier, `GOGC`-style pacing & soft memory limit | `SLANG_GC_STAT`, `SLANG_GC_VERIFY_MINOR`, `SLANG_GC_PERCENT`, `SLANG_GC_MEMLIMIT_MB` |
| Language server & formatter | Diagnostics, hover, goto-definition, completion, inlay hints, semantic tokens, deterministic formatting | [`slanganalyser`](https://github.com/dolphlabs/slang-analyser) (`slang.project`) |
| Backend CLI & arch linter | Scaffold layered services, fast live watch reloads, enforce architectural rules, run migrations | [`zokor_cli`](https://github.com/dolphlabs/zokor_cli) (`zokor newcomp`, `watch`, `check`) |
| Schema code generators | Generate typed `.sl` structs/codecs from GraphQL SDL or `.proto` definitions | [`graphqlc`](https://github.com/dolphlabs/graphql), [`protoc-gen-slang`](https://github.com/dolphlabs/grpc) |

### Compiler CLI & JSON diagnostics

```sh
slangc new billing              # scaffold slang.project, main.sl, .gitignore
slangc get                      # fetch git pkg dependencies and write slang.lock
slangc main.sl --dev --run      # fast unoptimized edit-run loop (about 10x faster C compiles)
slangc main.sl -o billing       # optimized native binary (-O3)
slangc main.sl --target linux-amd64 --static -o billing-linux   # static Linux binary (uses zig cc if installed)
slangc main.sl --target linux-arm64 --static --sysroot /opt/arm64-sysroot -o billing-arm64
slangc main.sl --emit-c         # write main.gen.c without invoking cc
slangc main.sl --json           # emit compile errors as JSON lines on stderr
slangc doc httpc client_post    # query signatures and docstrings offline
```

Cross-compiling uses `zig` (`zig cc -target <triple>`) automatically when on `PATH` or in `$SLANG_CACHE/zig/zig` (`~/.cache/slang/zig/zig`), falling back to `<triple>-gcc` for Linux targets or an explicit `--cc` / `SLANG_CC`. Note that static linking (`--static`) targets Linux (e.g. `linux-amd64` -> `x86_64-linux-musl`, `linux-arm64` -> `aarch64-linux-musl`); programs importing `crypto`, `sql`, or `compress` require target headers/archives via `OPENSSL_DIR` or `--sysroot`.

`--json` outputs one compact JSON object per error so agents and editors
can fix every file in one pass:

```json
{"file":"main.sl","line":14,"severity":"error","message":"undefined variable 'summ' (did you mean 'sum'?)"}
```

### Test runner & data-race detection

`slangc test` compiles all `*_test.sl` files alongside a package, runs
every `test_*` function in its own green task, and prints one summary
line when everything passes:

```sh
slangc test                     # run tests in the current package
slangc test -v --run retry      # verbose timing for tests matching "retry"
slangc test --race stdlib/net   # compile & run tests under ThreadSanitizer
slangc main.sl --race --run     # run a full binary with race detection enabled
SLANG_RACE=1 ./slangc app.sl --run
```

Under `--race` / `SLANG_RACE=1`, `slangc` compiles with `-fsanitize=thread`
and links runtime task-switch annotations (`sl_tsan_*`) so TSan tracks
green tasks accurately when they migrate across worker OS threads:

```slang
// counter_test.sl
fn worker(mtx: mutex, ch: chan[int]) {
    mutex_lock(mtx);
    // critical section protected across spawned tasks
    mutex_unlock(mtx);
    chan_send(ch, 1);
}

fn test_concurrent_handoff() {
    let mtx = make_mutex();
    let ch: chan[int] = make_chan(2);
    spawn worker(mtx, ch);
    spawn worker(mtx, ch);
    assert((chan_recv(ch) ?? 0) + (chan_recv(ch) ?? 0) == 2);
}
```

### Profiling & live task dumps (`pprof` & `SIGQUIT`)

Every compiled slang binary ships built-in task inspection and sampling
profilers without extra daemons:

- **Signal dump (`SIGQUIT` / `Ctrl-\`)**: sends a live snapshot of all
  running, runnable, and parked tasks with wait reasons (`chan send`,
  `chan recv`, `mutex`, `select`, `join`, `sleep`, `net io`) and `.sl`
  source file/line locations to `stderr` without terminating the process
  (set `SLANG_SIGQUIT_EXIT=1` to exit immediately after dumping):

```sh
kill -QUIT <pid>
```

```text

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
