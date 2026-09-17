# slang

> A statically typed language built primarily for server-side and network programming. Compiles to C.

slang is a statically typed language built primarily for server-side and network programming -- that is the focus, not a limit. It compiles to C, schedules M:N green threads, collects with a precise mark-sweep GC, and ships its standard library inside the compiler.

## Quick start

Install the compiler, then start a project:

```sh
git clone https://github.com/dolphlabs/slang && cd slang
sudo make install            # /usr/local by default; PREFIX=~/.local works too

slangc new hello
cd hello
slangc main.sl --run         # hello from hello
```

`make install` puts `slangc` in `$(PREFIX)/bin` and the runtime and
standard library in `$(PREFIX)/lib/slang` — both are needed, because
`slangc` splices its runtime C into every program it compiles. Remove it
all with `make uninstall`. `make dist` builds a relocatable tarball with
the same layout, which can be unpacked anywhere and run in place.

**Platforms.** CI builds and runs the full test suite on every merge to
`main` on Linux x86_64 (GCC), Linux arm64 (GCC) and macOS on Apple Silicon
(clang), and it is developed on macOS x86_64. Building needs a C compiler;
`net` over TLS, `crypto` and `httpc` over https also need OpenSSL headers
and `pkg-config` (on macOS: `brew install openssl pkg-config`).

Working on the compiler itself:

```sh
make                 # build ./slangc against this working tree
make test            # compile & run the example programs
make docs            # rebuild the documentation site
```

### Starting a project

```sh
slangc new myapp     # creates myapp/ with slang.project, main.sl, .gitignore
slangc new .         # same, in the directory you are already in
```

`slangc new` writes `slang.project` but **not** `slang.lock`. The lock is
derived: `slangc get` generates it from the `pkg` lines in
`slang.project`, and a lock file for a project with no dependencies
records nothing. Cargo and Go draw the same line — `cargo new` writes
`Cargo.toml` and not `Cargo.lock`.

Scaffolding lives in `slangc` rather than a companion tool because the
compiler already owns both formats: it parses `slang.project` and writes
`slang.lock`. A separate tool would have to reimplement a grammar it
does not control.

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
