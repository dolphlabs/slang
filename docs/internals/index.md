# How it works

> The compiler pipeline, the collector, the scheduler.

## How it works

```
main.sl ──loader──> packages ──lexer/parser──> ASTs ──codegen──> main.gen.c ──cc──> ./main
```

1. **Loader** (`src/loader.c`) — resolves imports (local directory,
   native package, stdlib, then `slang.project` pins), scans package directories for `.sl`
   files (in deterministic sorted order), merges them per package, and
   detects cycles via canonical paths.
2. **Lexer** (`src/lexer.c`) — tokenizes source into identifiers,
   keywords, literals, and operators.
3. **Parser** (`src/parser.c`) — recursive-descent parser producing an
   AST (`src/ast.h`).
4. **Code generator** (`src/codegen/`) — walks the ASTs, performs type
   inference and semantic checks (including `pub` enforcement), and
   emits readable C. The runtime in `runtime/` (GC, scheduler, pool,
   containers, native packages) is real C, spliced into every
   generated file so the binary stays self-contained. Split by
   concern: `core.c`, `infer.c`, `expr.c`/`stmt.c`, `program.c`,
   `liveness.c` (GC safepoint roots), and `native.c` (`NatSig`
   dispatch). `internal.h` holds the shared `CG` struct.

   Native-package *signatures* live under `src/codegen/pkg_<name>/`.
   Their C runtimes are `runtime/sl_<name>.c`. `json` uses
   `dispatch.c` because decode/encode are generic over the target
   type. Adding a fixed-signature package is a `pkg_<name>/` directory,
   a `runtime/sl_<name>.c` file, and one line in `loader.c`.
5. **Driver** (`src/main.c`) — glues it together and shells out to
   `cc`. Because GCC/Clang compile the generated C, you get their full
   optimizer for free.

Inspect what slang generates:

```sh
./slangc examples/hello/main.sl --emit-c && cat main.gen.c
```

## Memory management

Compiled programs embed a precise mark-sweep collector
(`runtime/sl_gc.c`). Allocations go through `sl_gc_alloc`. `main()`
registers the thread, starts the worker pool, and switches into the
main task. There is no `libgc` dependency.

What this means in practice:

- No manual memory management in slang; no leaks from string churn.
- Collection is tracing (mark-and-sweep), so reference cycles are
  collected — unlike refcounting.
- Cost: stop-the-world pauses. The allocator still serializes on a
  mutex (batched); that is the current throughput ceiling.
- Every pool worker is registered with the collector. A collection
  stops the world, walks safepoint roots, the run queue, parked
  tasks, and (for async-preempted tasks) a conservative stack scan.
- Pacing follows the live heap, like Go's default (`GOGC=100`): the next
  collection comes after allocating as much as survived the last one,
  and never before 8MB. The heap peaks near twice what is live, however
  much garbage a program makes — streaming three million database rows
  runs in under 20MB.
- `SLANG_GC_STAT=1` prints collection counts and pause times at exit.
  `SLANG_GC_THRESHOLD_KB=n` collects every n KB instead, with no pacing:
  for tests, since a rooting bug only shows when a collection lands at
  the one safepoint where an object is unrooted.

## Project layout

```
src/
  common.h       allocation helpers, growable string buffer, file I/O
  loader.h/.c    package discovery, merging, cycle detection
  lexer.h/.c     tokenizer
  ast.h          AST node definitions
  parser.h/.c    recursive-descent parser
  rtpath.h/.c    locate runtime/ next to slangc
  codegen.h      public codegen API (one function: codegen_program)
  codegen/       type checking + C emission
  main.c         driver: flags, invokes cc
runtime/       real C runtime spliced into generated programs
  sl_core.c sl_gc.c sl_containers.c sl_sched.c sl_pool.c
  sl_time.c sl_net.c sl_tls.c sl_json.c sl_proc.c sl_fs.c
stdlib/        slang-source packages (`import "http"`, `import "byteutil"`;
             `import "log"` is a native package — no source files)
examples/      one directory per example program
tests/         language tests plus tests/runtime/ (no slangc)
Makefile       build/test/clean
```

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
