# compress

> Package compress.

gzip, zlib and raw DEFLATE, over zlib (`-lz`, added only when a program
imports `compress`).

```slang
import "compress";

let gr = compress.gzip(body);
guard let gz = gr else let e = err_of(gr) { log.error(e); return; }

// decompression ALWAYS takes a ceiling -- see below
let ur = compress.gunzip(payload, 4194304);        // 4 MiB
guard let plain = ur else let e = err_of(ur) {
    log.warn("rejected: " + e);                     // names the limit
    return;
}
```

| Function | Signature |
|---|---|
| `compress.gzip` | `(b: bytes) -> result[bytes, str]` |
| `compress.gzip_level` | `(b: bytes, level: int) -> result[bytes, str]` |
| `compress.gunzip` | `(b: bytes, max_out: int) -> result[bytes, str]` |
| `compress.deflate` | `(b: bytes) -> result[bytes, str]` |
| `compress.inflate` | `(b: bytes, max_out: int) -> result[bytes, str]` |
| `compress.deflate_raw` | `(b: bytes) -> result[bytes, str]` |
| `compress.inflate_raw` | `(b: bytes, max_out: int) -> result[bytes, str]` |

**Decompression takes a mandatory output limit.** `max_out` is a
required argument, not an optional one with a generous default. The
expansion ratio is unbounded — 65 KB of gzip holds 64 MB of output, and
that ratio goes much further — so a program that decompresses anything
it did not itself produce is one hostile input away from the OOM killer.
The ceiling is enforced *before* the allocation that would cross it, not
by inspecting the result afterwards: rejecting a 64 MB bomb was measured
at 3.9 MB peak RSS against a 0.86 MB baseline. A default here would be a
number nobody chose, applied at every call site that never thought about
it.

**Three containers, because HTTP needs all three.** They are the same
compressed bits under different headers: `gzip` (RFC 1952) is what
servers send; `zlib` (RFC 1950) is what the `deflate` content-coding is
*supposed* to mean; raw (RFC 1951, no header) is what the servers that
get it wrong send instead — which is why `inflate_raw` exists rather
than being a purist's omission. They are not interchangeable, and each
decoder says so rather than producing garbage.

**Backed by zlib rather than written here**, unlike `regex`. That
package was written in-house because a backtracking engine has a
catastrophic input class and being immune to it by construction was the
point. DEFLATE has no equivalent argument — what it has is thirty years
of hostile input and a reference implementation on every platform slang
targets. A hand-written inflate would be a memory-safety surface with no
upside, since every bug in one is a buffer overrun driven by
attacker-controlled input.

## API

### `compress.gzip(bytes) -> result[bytes,str]`

### `compress.gzip_level(bytes, int) -> result[bytes,str]`

### `compress.deflate(bytes) -> result[bytes,str]`

### `compress.deflate_raw(bytes) -> result[bytes,str]`

### `compress.gunzip(bytes, int) -> result[bytes,str]`

### `compress.inflate(bytes, int) -> result[bytes,str]`

### `compress.inflate_raw(bytes, int) -> result[bytes,str]`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
