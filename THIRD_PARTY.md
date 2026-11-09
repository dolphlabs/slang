# Third-party software

slang itself is MIT-licensed (see [LICENSE](LICENSE)). This file says what it
touches that is not, and what that means for you.

**This repository contains no third-party source code.** There are no vendored
libraries, and the release tarball bundles none. The one third-party
material it carries is Unicode data, described below.

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

## Unicode data

The `unicode` package's tables, `runtime/sl_unicode_tables.c`, are generated
from the Unicode Character Database (`UnicodeData.txt`, `CaseFolding.txt` and
`DerivedNormalizationProps.txt`) by `runtime/gen_unicode_tables.py`. The
release tarball ships that file, and a program that imports `unicode` has the
tables compiled into it. The conformance test reads two of the Database's
files, kept unmodified in `tests/runtime/unicode/` (`NormalizationTest.txt`,
`CaseFolding.txt`); those are not in the tarball.

All of it is used under the Unicode License v3, which allows use, copying,
modification and distribution provided this notice appears with the copies
or in their documentation. The generated file carries it in its header and
as data (below), the test files carry Unicode's own headers, and it is
reproduced here:

```
UNICODE LICENSE V3

COPYRIGHT AND PERMISSION NOTICE

Copyright © 1991-2026 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.
```

**A program that imports `unicode` carries the notice itself.** The tables
come with the notice compiled in as data (`sl_uc_license` in
`runtime/sl_unicode_tables.c`), so every binary that contains Unicode-derived
data also contains the full notice; `make test` checks that it is there, and
that a program without `unicode` carries neither. If you ship such a program,
listing the notice in its own documentation as well does no harm.

The licence text is also at [LICENSES/Unicode-3.0.txt](LICENSES/Unicode-3.0.txt)
(SPDX identifier `Unicode-3.0`, which the generated file declares), and the
release tarball includes that directory.

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
