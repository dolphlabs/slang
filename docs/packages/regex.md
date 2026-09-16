# regex

> Package regex.

Regular expressions on `str` or `bytes`, matched by slang's own
Thompson NFA — no external library, so a program that matches text
stays as dependency-free as a plain TCP one. `compile` returns an
opaque `rawptr` handle (freed with `regex.free`, like `net.tls_*` and
`sql`), and a bad pattern comes back as a descriptive
`result[rawptr, str]`.

**Matching is linear time, always.** There is no backtracking, so the
classic catastrophic pattern `(a+)+$` — which makes a backtracking
engine take exponential time on a hostile input — runs in the same
microseconds here as any other pattern. That is the point of choosing
this engine for a server language: patterns and subjects both arrive
from the network. The price is the RE2/Go one, and it is not
negotiable: **no backreferences and no lookaround**. Both require
backtracking; `(?=...)` and friends are a compile error, not a silent
mis-parse.

| Function | Signature |
|----------|-----------|
| `regex.compile(pat)` | `result[rawptr, str]` |
| `regex.free(re)` | — |
| `regex.groups(re)` | `int` — number of capture groups |
| `regex.is_match(re, s)` | `bool` — `s` is a `str` |
| `regex.is_match_bytes(re, b)` | `bool` — `b` is `bytes` |
| `regex.find(re, s)` / `find_bytes(re, b)` | `[int]` |
| `regex.find_at(re, s, from)` / `find_bytes_at(re, b, from)` | `[int]` |

`find` returns byte offsets as `[start, end, g1start, g1end, ...]`, or
an **empty list** when there is no match — so the result is GC-owned
and there is no match handle to leak. `find_at` starts at an offset,
which is how you walk every match.

```slang
import "regex";

let cr = regex.compile("(\\d{4})-(\\d{2})-(\\d{2})");
guard let re = cr else let e = err_of(cr) {
    log.error("bad pattern: " + e);   // e.g. "missing ) at offset 9"
    exit(1);
}

if regex.is_match(re, "due 2026-09-09") {
    let m = regex.find(re, "due 2026-09-09");
    println(to_str(m[0]) + ".." + to_str(m[1]));   // whole match: 4..14
    println(to_str(m[2]) + ".." + to_str(m[3]));   // year:        4..8
}
regex.free(re);
```

Supported: literals, `.`, classes `[a-z]` `[^...]` `[[:digit:]]`,
escapes `\d \D \w \W \s \S \b \B \A \z \xHH`, quantifiers
`* + ? {n} {n,} {n,m}` and their lazy `?` forms, groups `(...)` and
`(?:...)`, alternation `|`, anchors `^ $`. Matching is leftmost-first
(Perl-style priority), and `.` does not match `\n`.

Subjects are matched with an explicit length, so a `bytes` containing
NUL matches correctly rather than stopping at the NUL — and `\D`
matches a NUL byte like any other non-digit.

Bounds, so a hostile pattern can't exhaust memory or stack: 4096
compiled instructions, 100 nesting levels, 32 capture groups, and
`{n,m}` counts up to 1000. Each is a descriptive compile error, never
a crash.

A compiled regex is safe to share across tasks, and is meant to be:
it carries a small pool of reusable match buffers, so concurrent
matchers allocate nothing per match. Compiling is the expensive part
(it is also the only part that grows the task stack) — compile once,
match many times, ideally not once per request.

**Where this lands on speed.** Measured single-threaded on
`^(GET|POST|PUT) (/[a-z0-9/_-]*) HTTP/1\.([01])$` against a 26-byte
subject, 200k iterations:

| engine | matches/sec | on `(a+)+$` vs a hostile input |
|--------|-------------|-------------------------------|
| slang `regex` | ~721k | 2µs, correct answer |
| POSIX `regexec` | ~372k | fast here, but no limits |
| PCRE2 (interpreted) | ~2.4M | 0.2s, then gives up (`MATCHLIMIT`) |
| PCRE2 (JIT) | ~8.6M | same — JIT does not save it |

So: ~1.9x faster than libc's POSIX engine, and several times slower
than PCRE2 on *benign* input — PCRE2's interpreter and especially its
JIT are very good, and this is an honest gap. The trade is deliberate:
on adversarial input the ordering inverts completely, because linear
time is a guarantee here and a hope there. `is_match` is markedly
cheaper than `find` (it binds no capture slots at all), so prefer it
when you only need a yes/no. Matching scales with tasks — ~3.2M/sec
across 16.

Because matching never grows the task stack, regex is cheap to use per
connection: 600 concurrently-live tasks each matching and then parking
peak at **3.9MB RSS** — about 17x lighter than the same shape holding
`sql` connections (65.9MB), which does grow every task's stack.

## API

### `regex.compile(str) -> result[rawptr,str]`

### `regex.free(rawptr)`

### `regex.groups(rawptr) -> int`

### `regex.is_match(rawptr, str) -> bool`

### `regex.is_match_bytes(rawptr, bytes) -> bool`

### `regex.find(rawptr, str) -> [int]`

### `regex.find_at(rawptr, str, int) -> [int]`

### `regex.find_bytes(rawptr, bytes) -> [int]`

### `regex.find_bytes_at(rawptr, bytes, int) -> [int]`
