# multipart

> Package multipart.

`multipart/form-data` (RFC 7578), the body of HTML file uploads, read as a
stream so a large upload never has to fit in memory.

```slang
import "multipart";

let b = multipart.boundary_of(content_type) ?? "";
let p = multipart.parser(b);
// as each chunk of the body arrives:
let er = multipart.feed(p, chunk);
guard let evs = er else { return bad_request(); }
for e in evs {
    if e.kind == multipart.PART { /* e.part.name, filename, content_type */ }
    else if e.kind == multipart.DATA { /* the next e.data bytes of the part */ }
    else if e.kind == multipart.PART_END { /* the part is complete */ }
}
// when the body ends: multipart.finish(p) is an error if it was cut short
```

Part data comes out as it arrives; the parser holds back only the bytes
that could start a boundary. Part headers are limited to
`max_header_bytes` (8 KB) and parts to `max_parts` (1000). `filename*`
(RFC 5987) is decoded. `parse(body, boundary)` reads a body already in
memory. `body(boundary)`, `add_field`, `add_file`, `close` and
`content_type` build one for an upload.

## API

### `let PART = 0; // a part starts: see Event.part`

### `let DATA = 1; // part data: Event.data`

### `let PART_END = 2; // the current part is complete`

### `let DONE = 3; // the closing boundary: nothing more`

### `struct Part`

### `struct Event`

### `gc struct Parser`

### `fn boundary_of(content_type: str) -> opt[str]`

The boundary parameter of a multipart Content-Type.

### `fn parser(boundary: str) -> Parser`

### `fn feed(p: Parser, chunk: bytes) -> result[[Event], str]`

Takes the next bytes of the body; returns what they completed.

### `fn finish(p: Parser) -> result[bool, str]`

The body has ended: an error unless the closing boundary was seen.

### `struct Item`

A whole part with its data, from parse.

### `fn parse(body: bytes, boundary: str) -> result[[Item], str]`

Every part of a body already in memory.

### `gc struct Body`

### `fn body(boundary: str) -> Body`

A body to fill with fields and files; boundary should be random and not occur in the data (a 32-character hex token from a CSPRNG does).

### `fn add_field(w: Body, name: str, value: str)`

### `fn add_file(w: Body, name: str, filename: str, content_type: str, data: bytes)`

### `fn close(w: Body) -> bytes`

The finished body and the Content-Type to send it with.

### `fn content_type(w: Body) -> str`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
