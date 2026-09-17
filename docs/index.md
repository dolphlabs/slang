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
`net` over TLS, `crypto` and `httpc` over https also need OpenSSL (macOS:
`brew install openssl`; Debian/Ubuntu: `apt install libssl-dev`).

slangc finds OpenSSL itself: `OPENSSL_DIR` if set, then `pkg-config`, then
the standard Homebrew and MacPorts locations, then `brew --prefix`, then the
system headers. If none of those finds it and compilation fails, slangc says
so and suggests the fix, rather than leaving only the compiler's
"openssl/… file not found".

Working on the compiler itself:

```sh
make                 # build ./slangc against this working tree
make test            # compile & run the example programs
make docs            # rebuild the documentation site
```

### Testing

Tests live next to the code they test, Go-style: files named `*_test.sl`
hold functions named `test_*`, taking nothing and returning nothing, which
fail through `assert` or `panic`.

```slang
// calc_test.sl
fn test_add() {
    assert(add(2, 3) == 5);
}

fn test_clamp() {
    let got = clamp(15, 0, 10);       // private functions are reachable:
    assert(got == 10, "got " + to_str(got));   // tests are in the package
}
```

```sh
slangc test                 # the package in the current directory
slangc test path/to/pkg     # another one
slangc test --run clamp     # only tests whose name contains "clamp"
```

```
ok   test_add (52us)
FAIL test_clamp (30us)
     got 15 at calc.test_clamp:7
FAIL: 1 of 2 failed (190us)
```

- **Each test runs in its own task**, so a failing test is reported with
  its message and location and the run carries on. Tests run one at a
  time, so output stays in order.
- **`*_test.sl` files never reach a normal build.** Test helpers can't leak
  into a program, and a test file's imports can't add link flags to one.
- **Programs are testable too.** When the package is a program rather than
  a library, `slangc test` does not run its top-level statements: the test
  runner is `main`. Functions, structs and methods are all there.
- Exit status is 0 when every test passes, 1 when any fails, and 2 when the
  tests cannot be run (a `test_` function with parameters, say). A package
  with no test files exits 0 and says so.
- `--keep` keeps the generated runner and prints where it is.

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
