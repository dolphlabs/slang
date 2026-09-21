# Third-party software

slang itself is MIT-licensed (see [LICENSE](LICENSE)). This file says what it
touches that is not, and what that means for you.

**This repository contains no third-party source code.** There are no vendored
libraries, and the release tarball bundles none.

## System libraries a compiled program links

`slangc` links a library only when the program uses the package that needs
it, and always from your system, never from a copy shipped with slang:

| A program that uses | Links | Licence of that library |
|---|---|---|
| `net` over TLS (`net.tls_*`), `crypto`, `httpc` over https | OpenSSL (`libssl`, `libcrypto`) | OpenSSL 3.x: Apache-2.0. OpenSSL 1.1.1 and earlier: the dual OpenSSL/SSLeay licence |
| `sql` | SQLite (`libsqlite3`) | Public domain |
| `compress`, and gzip in `httpc` | zlib (`libz`) | The zlib licence |
| `link "name";` | Whatever library you name | Its own |

A program with none of those links only the C library and `pthread`.

**If you distribute a program built with slang, the terms of the libraries it
links apply to your distribution.** Check them for the version you link.
slang's own runtime, which the compiler embeds in every program it produces,
is covered by the MIT licence above; keeping the copyright notice with it is
the only condition.

## Things this repository refers to but does not ship

- **Fonts on the documentation site.** The generated pages ask Google Fonts, at
  view time, for Archivo, IBM Plex Sans and IBM Plex Mono (SIL Open Font
  License 1.1). Nothing is downloaded into, or redistributed from, this
  repository.
- **The Contributor Covenant**, version 2.1, in
  [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), is used under its Creative Commons
  Attribution 4.0 licence; the attribution is in that file.
- **Dependencies of the benchmarks in `bench/`.** The programs there are this
  project's own, written in the languages being compared. Some declare dependencies (Go modules, crates, npm packages, Maven and
  NuGet packages, pip requirements) in their manifests and lockfiles, which
  each language's package manager fetches when you run the suite, under those
  packages' own licences. None is vendored.
