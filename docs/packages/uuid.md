# uuid

> Package uuid.

UUIDs per RFC 9562: make version 4 (random) and version 7 (time-ordered),
check, parse and convert. An id is a plain `str` in canonical form (36
characters, lowercase hex, hyphens at 8, 13, 18 and 23), the form JSON,
logs and Postgres's `uuid` text already use, so it crosses those
boundaries unconverted and has exactly one spelling to compare or key a
map by.

```slang
import "uuid";

let r = uuid.v7();
guard let id = r else let e = err_of(r) {
    panic(e);                          // only if the OS has no randomness
}
uuid.is_valid(id);                     // true: canonical form only
uuid.version(id) ?? 0;                 // 7
uuid.time_ms(id) ?? 0;                 // unix ms it was made

let p = uuid.parse("{0190F4E2-7C1A-7B3E-9F21-6C0D5A4E8B17}");
// ok("0190f4e2-7c1a-7b3e-9f21-6c0d5a4e8b17"); also urn:uuid: and 32 hex
let bad = uuid.parse("0190f4e2-7c1a");
// err("uuid: want 36 characters (8-4-4-4-12 hex digits), got 13")
```

Use `v7` for anything stored, primary keys above all: its first 48 bits
are the creation time in milliseconds, so ids sort by time and new rows
append to an index instead of landing on random pages. Within one
millisecond the order is random, because `v7` keeps no state and any task
may call it without a lock. `v4` is 122 random bits and reveals nothing,
not even when it was made. Both draw from `crypto.rand`, and return an
error rather than an id from a weaker source. `v7_at(unix_ms)` stamps a
given time (tests, ids that carry an event's time); `to_binary` and
`from_binary` convert to and from the 16-byte form; `uuid.NIL` and
`uuid.MAX` are the RFC's two special values. `is_valid` accepts any
version and variant, so ids from Postgres's `gen_random_uuid()` or other
services pass.

## API

### `let NIL = "00000000-0000-0000-0000-000000000000";`

The nil and max UUIDs (RFC 9562 sections 5.9 and 5.10).

### `let MAX = "ffffffff-ffff-ffff-ffff-ffffffffffff";`

### `fn v4() -> result[str, str]`

A random UUID, version 4: 122 random bits.

### `fn v7() -> result[str, str]`

A time-ordered UUID, version 7, stamped with the current wall-clock time: 48 bits of unix milliseconds, then 74 random bits.

### `fn v7_at(unix_ms: int) -> result[str, str]`

A version 7 UUID stamped with `unix_ms` instead of the clock: for tests, and for ids that must carry an event's own time. Errors if `unix_ms` is negative or does not fit in 48 bits.

### `fn is_valid(s: str) -> bool`

Is `s` a UUID in canonical form: 36 characters, lowercase hex digits, hyphens at 8, 13, 18 and 23? Any version and variant passes, so ids made elsewhere (Postgres's gen_random_uuid, another service) are accepted. Upper case, braces and urn:uuid: are not: run those through `parse`.

### `fn parse(s: str) -> result[str, str]`

The canonical form of a UUID written any common way: canonical, upper or mixed case, in braces ({...}), as a urn:uuid: URN, or as 32 hex digits without hyphens. The error names the position and what was expected there.

### `fn version(s: str) -> opt[int]`

The version number of a canonical UUID (4 for v4, 7 for v7, 0 for NIL), or none if `s` is not canonical.

### `fn time_ms(s: str) -> opt[int]`

When a v7 UUID was made, in unix milliseconds. none if `s` is not a canonical version 7 UUID with the RFC 9562 variant: other versions keep no time, or keep it in another layout.

### `fn to_binary(s: str) -> result[bytes, str]`

The 16 bytes of a UUID, most significant first: the binary form databases store (Postgres `uuid` on the wire, a BINARY(16) column). Accepts every spelling `parse` does.

### `fn from_binary(b: bytes) -> result[str, str]`

The canonical form of 16 bytes, the reverse of `to_binary`.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
