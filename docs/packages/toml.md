# toml

> Package toml.

TOML v1.0.0: decode a config file into your own types, or convert it to
JSON.

```slang
import "toml";

struct Db { host: str, port: int, replicas: [str], timeout_ms: opt[int] }
struct Config { name: str, db: Db }

let r: result[Config, str] = toml.decode(text);
guard let cfg = r else let e = err_of(r) { panic(e); }   // "toml: line 4: ..."

toml.to_json(text);                                      // result[str, str]
```

`decode` is `to_json` then `json.decode`, so a document decodes into
whatever JSON does: structs, `gc struct`s, lists, maps, `opt` (a missing
key is `none`) and enums, and an offset date-time into a `timez.Time`.
Tables keep their keys in document order.

**Values in JSON.** Strings, integers and booleans are the same JSON
values. Floats are numbers, except `inf` and `nan`, which have no JSON
form and become `null`, as `json.encode` writes them. An offset
date-time is an RFC 3339 string with `T` and `Z` (`1979-05-27T07:32:00Z`,
`...-07:00`); local date-times, dates and times are strings as written.
A string may hold U+0000 (as `\u0000`), though a slang `str` cannot.

**Strictness.** All of TOML 1.0, and everything it forbids is an error
naming the line: a key or table defined twice, a table extended after it
was closed, an integer outside 64 bits, an invalid date, a control
character in a string, a bare CR, invalid UTF-8. Nesting is limited to
256 levels. A subnormal float (below about 2.2e-308) is refused, as
`to_float` refuses one. tests/toml_parity checks 748 documents against
Python's `tomllib`: the spec's examples, one invalid document per rule,
and seeded random and mutated ones.

**Cost.** One pass over the bytes builds a tree that holds each value's
JSON text, so nothing is decoded twice. A string with nothing to escape
and a plain decimal integer are a single copy of their source. On a 1.1
MB document of 6,000 tables, `to_json` took about 220 ms against about
180 ms for Go's BurntSushi/toml decoding into `map[string]any` and about
550 ms for Python's `tomllib` (Linux container; ratios, the host was
throttled). A config file of a few KB parses in microseconds.

## API

### `fn to_json(text: str) -> result[str, str]`

The document as JSON.

### `fn decode[T](text: str) -> result[T, str]`

The document decoded into T, as json.decode would decode its JSON.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
