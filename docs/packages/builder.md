# builder

> Package builder.

Assembling a result one piece at a time with `+` is **quadratic**: `a + b`
allocates and copies both sides, so the cost is the sum of every
intermediate length. Building 80 KB one byte at a time takes about two
seconds, and a megabyte would take minutes. `builder` collects the pieces
and copies each once, at the end.

```slang
import "builder";

let b = builder.new_str();
b.write("hello").write(", ").write(name).write_int(42).write_line("!");
let s = b.finish();                    // one allocation, linear in the total

let y = builder.new_bytes();
y.write_byte(104).write(b"ello").write_str(" world");
let raw: bytes = y.finish();
```

`Str` is for text and `Bytes` for binary data. Both chain, report
`size()` in bytes without assembling anything, and offer `finish()` (which
can be called again after more writes), `take()` (finish and start over)
and `reset()`. `Bytes.write_byte` fills a 512-byte chunk in place, so a
million single-byte writes make about two thousand allocations rather than a
million: 4 million of them take 136 ms. `Bytes` keeps a **copy** of what you
write, because bytes are mutable and a later change of yours must not
rewrite what was already written.

For assembling a `[bytes]` you already hold, `strings.join_bytes(parts,
sep)` is the counterpart of `strings.join`. `bench/builder/` prints the
naive loop beside the builder.

## API

### `gc struct Str`

### `fn new_str() -> Str`

### `fn write(self: Str, s: str) -> Str`

Appends, and returns the builder so writes chain. A str is immutable, so the builder holds the caller's value, not a copy.

### `fn write_int(self: Str, n: int) -> Str`

### `fn write_line(self: Str, s: str) -> Str`

### `fn size(self: Str) -> int`

The bytes written so far, without assembling anything.

### `fn is_empty(self: Str) -> bool`

### `fn finish(self: Str) -> str`

The whole result, in one allocation. Can be called again after more writes; each call assembles what is there, so ask once when you are done rather than after every write.

### `fn take(self: Str) -> str`

finish() and start over.

### `fn reset(self: Str) -> int`

### `gc struct Bytes`

### `fn new_bytes() -> Bytes`

### `fn write_byte(self: Bytes, b: int) -> Bytes`

### `fn write(self: Bytes, b: bytes) -> Bytes`

Appends a copy. Bytes are mutable in slang, so keeping the caller's own value would let a later change of theirs rewrite what was already written.

### `fn write_str(self: Bytes, s: str) -> Bytes`

Text goes in as its UTF-8 bytes. `to_bytes` already makes a fresh value, so a long string is kept as-is rather than copied twice.

### `fn size(self: Bytes) -> int`

### `fn is_empty(self: Bytes) -> bool`

### `fn finish(self: Bytes) -> bytes`

The whole result, in one allocation. Leaves the builder as it was, so it can be written to and finished again; call it once when you are done rather than after every write.

### `fn take(self: Bytes) -> bytes`

### `fn reset(self: Bytes) -> int`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
