# byteutil

> Package byteutil.

Search, trim, and split on the `bytes` type — no new syntax. The
package cannot be named `bytes` because that token is the type.

```slang
import "byteutil";

byteutil.find(b"hello", 0, 108);     // 2, or -1
byteutil.has_prefix(b"hello", b"he");
byteutil.has_suffix(b"hello", b"lo");
byteutil.trim(b"  hi\r\n");          // b"hi" (space/tab/CR/LF)
byteutil.split(b"a,b", 44);          // [b"a", b"b"]
```

## API

### `fn find(b: bytes, from: int, target: int) -> int`

Index of the first `target` byte in `b` at or after `from`, or -1 if it does not occur. `target` is a byte value, not a substring: 44 is a comma.

### `fn has_prefix(b: bytes, prefix: bytes) -> bool`

Does `b` begin with `prefix`? A prefix longer than `b` is false rather than an error.

### `fn has_suffix(b: bytes, suffix: bytes) -> bool`

Does `b` end with `suffix`? A suffix longer than `b` is false rather than an error.

### `fn trim(b: bytes) -> bytes`

`b` without leading or trailing ASCII whitespace -- space, tab, CR and LF. Returns a new `bytes`; the input is unchanged.

### `fn split(b: bytes, sep: int) -> [bytes]`

Split `b` on every occurrence of the `sep` byte. Adjacent separators yield empty elements, so the result always has one more element than there were separators.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
