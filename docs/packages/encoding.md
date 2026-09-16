# encoding

> Package encoding.

Hex, base64, base64url, percent-encoding and query strings — the four
ways arbitrary bytes travel through a channel that only carries text.

```slang
import "encoding";

encoding.hex_encode(crypto.sha256(b"abc"));   // "ba7816bf8f01cfea..."
encoding.base64_encode(b"aladdin:opensesame");// HTTP Basic credentials
encoding.base64url_encode(sig);               // a JWT segment: -_ alphabet, no padding
encoding.url_encode("a b&c");                 // "a%20b%26c"
encoding.form_encode("a b&c");                // "a+b%26c"

let q = "/search?q=hello+world&page=2";
guard let term = encoding.query_get(q, "q") else { return; }   // "hello world"
encoding.query_keys(q);                                        // ["q", "page"]
```

| Function | Signature |
|---|---|
| `encoding.hex_encode` | `(b: bytes) -> str` |
| `encoding.hex_decode` | `(s: str) -> result[bytes, str]` |
| `encoding.base64_encode` | `(b: bytes) -> str` |
| `encoding.base64_decode` | `(s: str) -> result[bytes, str]` |
| `encoding.base64url_encode` | `(b: bytes) -> str` |
| `encoding.base64url_decode` | `(s: str) -> result[bytes, str]` |
| `encoding.url_encode` | `(s: str) -> str` |
| `encoding.url_decode` | `(s: str) -> result[str, str]` |
| `encoding.form_encode` | `(s: str) -> str` |
| `encoding.form_decode` | `(s: str) -> result[str, str]` |
| `encoding.query_get` | `(url: str, key: str) -> opt[str]` |
| `encoding.query_keys` | `(url: str) -> [str]` |

Like `regex`, `strings` and `os` — and unlike `crypto` and `sql` — this
is pure computation, so importing it adds no link flag.

Four things worth knowing:

- **Encoders are infallible; decoders are not.** Any byte string has a
  hex form, so `hex_encode` returns a bare `str`. Decoding takes input
  the program did not produce — a query string, a header, a token — so
  every decoder returns `result[_, str]`, and the message names the byte
  offset it gave up at. "invalid base64" about a 400-character token is
  not a diagnosis.

- **`url_*` and `form_*` differ only in `+`, and that is exactly why
  they have separate names.** In `application/x-www-form-urlencoded` a
  space is `+`; in a URI it is `%20`. Decoding a form body with
  `url_decode` leaves literal `+` where every space belongs, and nothing
  reports it — the failure surfaces later as a lookup that does not
  match. One function with a flag would make that the default mistake.

- **`%00` is an error, not a truncation.** `url_decode` and
  `form_decode` return `str`, which is NUL-terminated, so a decoded zero
  byte would silently cut the value short. They refuse it and say so.
  `hex_decode` and `base64_decode` return `bytes`, which carries an
  explicit length, so a zero byte there is ordinary data and round-trips
  exactly.

- **`query_get` is `opt`, and `query_keys` is a list.** A missing
  parameter is absent data, not bad data, so it is `opt[str]` — the
  README rule above. Keys come back as a list rather than a map because
  a query may legally repeat a key and a map would have to drop one,
  the same reason `os.environ` is a list. `query_get` takes the first
  value; a bare `?debug` is present with an empty value, not absent.

Percent-escapes are emitted uppercase (RFC 3986 §2.1) and hex digests
lowercase (what `sha256sum`, git and every API that returns one use).
Both decoders accept either case.

## API

### `encoding.hex_encode(bytes) -> str`

### `encoding.hex_decode(str) -> result[bytes,str]`

### `encoding.base64_encode(bytes) -> str`

### `encoding.base64_decode(str) -> result[bytes,str]`

### `encoding.base64url_encode(bytes) -> str`

### `encoding.base64url_decode(str) -> result[bytes,str]`

### `encoding.url_encode(str) -> str`

### `encoding.url_decode(str) -> result[str,str]`

### `encoding.form_encode(str) -> str`

### `encoding.form_decode(str) -> result[str,str]`

### `encoding.query_get(str, str) -> opt[str]`

### `encoding.query_keys(str) -> [str]`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
