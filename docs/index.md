# slang

> A statically typed language built primarily for server-side and network programming. Compiles to C.

slang is a statically typed language built primarily for server-side and network programming -- that is the focus, not a limit. It compiles to C, schedules M:N green threads, collects with a precise mark-sweep GC, and ships its standard library inside the compiler.

## Quick start

```sh
make                 # build the slangc compiler
make test            # compile & run the example programs
```

Compile a slang program:

```sh
./slangc examples/hello/main.sl     # produces ./main
./main                              # run it
```

Useful flags:

| Flag        | Effect                                              |
|-------------|-----------------------------------------------------|
| `-o <name>` | Choose the output binary name                       |
| `--emit-c`  | Only write the generated C file (no compilation)    |
| `--keep-c`  | Keep the generated C file after compiling           |
| `--run`     | Compile, then immediately execute the result        |
| `get`       | Fetch `slang.project` pins and write `slang.lock`   |

Want to see everything at once instead of one feature at a time? See
**[`demo/`](demo/)** — a full server (dice game, guestbook wall, live
dashboard) exercising every tier: `http`/`link`, `net.tls_*`, `json`,
`spawn`/`chan[T]`, `proc` graceful shutdown, local package imports,
and C interop, with a real HTML/CSS/JS frontend. `cd demo && ./run.sh`.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
