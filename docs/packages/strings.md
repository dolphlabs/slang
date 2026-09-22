# strings

> Package strings.

Search, trim, case, split and join on `str`. The package cannot be named
`str` because that token is the type — the same reason Go calls its own
`strings`.

```slang
import "strings";

strings.find("hello world", "world");   // 6, or -1
strings.rfind("a/b/c", "/");            // 3
strings.contains("hello", "ell");
strings.has_prefix("hello", "he");
strings.has_suffix("hello", "lo");
strings.count("a,b,c", ",");            // 2

strings.trim("  hi \r\n");              // "hi" (space/tab/CR/LF)
strings.trim_start(s); strings.trim_end(s);
strings.to_upper("hi"); strings.to_lower("HI");   // ASCII only

strings.slice("hello", 1, 3);           // "el"
strings.slice("hello", -3, 5);          // "llo" — negative counts back
strings.repeat("ab", 3);                // "ababab"
strings.replace("a,b,c", ",", " | ");

strings.split("a,b,,c", ",");           // ["a", "b", "", "c"]
strings.join(parts, ",");               // the inverse of split
strings.join_bytes(parts, b",");        // the same for [bytes]: sized once, copied once

strings.from_float(0.1 + 0.2);          // "0.30000000000000004"
```

`to_str` prints a float with six significant digits, which suits output
and loses information: `to_str(123456789.125)` is `"1.23457e+08"`.
`from_float` returns the shortest text that `to_float` reads back as
exactly the same number — use it whenever a float is stored or sent.
NaN and the infinities come out as `NaN`, `Infinity` and `-Infinity`.

This is a compiler-provided native package, and it has to be: `str`
supports `len`, `+` and `==` and nothing else — it cannot be indexed or
sliced — so none of it could be written in slang without converting to
`bytes` and back on every call. `byteutil` covers the `bytes` side.

Three behaviours worth knowing:

- **Indices are byte offsets and the case operations are ASCII-only.**
  `str` is UTF-8 bytes; doing better means shipping a Unicode table and
  a normalisation policy, which is a different project. Treat these as
  byte operations, because that is what they are.
- **`slice` clamps rather than panics.** Slicing is how you narrow a
  string you just searched, and a `find` that returned -1 on the line
  above should not turn the next line into a crash. A negative index
  counts from the end.
- **`split` and `join` are exact inverses.** Adjacent separators produce
  empty elements, so the result always has `count(s, sep) + 1` elements
  and `join(split(s, sep), sep) == s` for any non-empty separator. An
  empty separator splits into single bytes.

## API

### `strings.find(str, str) -> int`

### `strings.rfind(str, str) -> int`

### `strings.contains(str, str) -> bool`

### `strings.has_prefix(str, str) -> bool`

### `strings.has_suffix(str, str) -> bool`

### `strings.count(str, str) -> int`

### `strings.trim(str) -> str`

### `strings.trim_start(str) -> str`

### `strings.trim_end(str) -> str`

### `strings.to_upper(str) -> str`

### `strings.to_lower(str) -> str`

### `strings.slice(str, int, int) -> str`

### `strings.repeat(str, int) -> str`

### `strings.replace(str, str, str) -> str`

### `strings.split(str, str) -> [str]`

### `strings.join(NA_ARR_STR, str) -> str`

### `strings.join_bytes(NA_ARR_BYTES, bytes) -> bytes`

### `strings.from_float(float) -> str`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
