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
the same layout, which can be unpacked anywhere and run in place. Every
[release](https://github.com/dolphlabs/slang/releases) has one for Linux
x86_64 and arm64 and macOS arm64 and x86_64, with their SHA-256 sums.

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

Tests live in `*_test.sl` files and run with `slangc test` — covered in
the Testing section.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
