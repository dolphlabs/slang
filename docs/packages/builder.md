# builder

> Package builder.

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
