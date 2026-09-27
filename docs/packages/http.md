# http

> Package http.

HTTP/1.1 over `link` / `wire` / `until` / `fault`. Parse a request
from `bytes`, or `read` from a connection into a caller-sized `wire`
(the max request size). `read` takes the unconsumed prefix length and
returns `Incoming` with leftover compacted to the front of the wire,
so one connection can carry many requests. `write` serializes a
`Response` through an arena. Headers are stored lowercased;
`header(req, name)` looks up case-insensitively. A body is framed by
`Content-Length` or by `Transfer-Encoding: chunked` (chunk extensions
ignored, trailers read and discarded). `wants_close` follows HTTP/1.1
keep-alive (and HTTP/1.0 close-by-default).

Framing decides where a request ENDS, so it is a security boundary: if a
proxy in front and this server frame the same bytes differently, the
leftover is read as a second request the proxy never saw (request
smuggling). `read` and `parse` therefore refuse, rather than guess at:

- `Transfer-Encoding` together with `Content-Length`, or in an HTTP/1.0
  request;
- any coding but exactly `chunked` (no lists such as `gzip, chunked`);
- a repeated `Content-Length` or `Transfer-Encoding` header;
- a `Content-Length` longer than 18 digits, or not all digits;
- chunk-size lines over 1KB, sizes over 15 hex digits, bare LFs, chunk data
  not followed by CRLF, or trailers over 8KB.

**After `read` returns an error, close the connection** (the examples all
`return`). The error means this server could not tell where the request
ended, so it cannot tell where the next one begins either.

```slang
import "http";

fn serve(c: link) {
    let ra = arena_new(16384);
    let sa = arena_new(16384);
    let buf = ra.wire(8192);
    let filled = 0;
    while true {
        let rr = http.read(&mut c, buf, filled, until_never());
        guard let got = rr else { return; }
        let wr = http.write(&mut c, http.ok_text(got.req.path), &mut sa,
                            until_never());
        guard let _n = wr else { return; }
        sa.reset();
        if http.wants_close(got.req) { return; }
        filled = got.filled;
    }
}
```

See `examples/httpd/` for a listener loop on this package.

This works because every `spawn`ed thread has `SIGTERM`/`SIGINT`
blocked in its own signal mask from birth (inherited at creation,
restored in the spawning thread right after) — so the OS can only
ever pick the main thread to run the handler, which is what lets the
main thread's blocked `accept()` call reliably observe the
interruption instead of the signal silently landing on some unrelated
connection's worker thread mid-request. There's a narrow startup race
inherent to this: a signal that arrives in the brief window before
`main()` installs the handler gets the OS's default disposition
(immediate termination) instead of graceful handling, same as any
signal-handling program.

## API

### `gc struct Request`

`raw_headers` is exactly the CRLF-separated "name: value" lines this request's header block was made of, unparsed -- not a map[str]str. Building a map costs an allocation for the map plus roughly two more per header, on every request, whether or not anything ever reads a header; most requests never do. `header`/`header_or` scan this directly (strings.find_field, no allocation for the search itself); `headers()` builds a map from it on demand for a caller that genuinely wants one. Constructed only by `parse`/`read` (off the wire) or `request` (validated, from a map) -- never assign this field directly from unvalidated bytes; a value containing "\r\n" inside a hand-built block is a second header no map ever held.

### `gc struct Incoming`

### `gc struct Response`

### `fn header(r: Request, name: str) -> opt[str]`

### `fn header_or(r: Request, name: str, fallback: str) -> str`

header()'s two real call sites (Ctx.header in zokor, the WebSocket handshake) are both `header(...) ?? fallback` already -- this is that, without the opt allocation `??` unwraps.

### `fn headers(r: Request) -> map[str]str`

Every header a request carries, as a map -- built fresh on each call by scanning raw_headers once. Nothing in either repo iterates a request's headers today (confirmed by grep), which is what makes "built on demand" the right default over a cached field: a cache nothing reads is pure cost. Walks the same line shape scan_headers does, for a different reason (that one validates and extracts two offsets; this one assumes an already-valid block and extracts every name and value) -- kept as two functions rather than one parameterized by what to do with each line, which would obscure both to save repeating six lines.

### `fn request(method: str, path: str, version: str,`

Builds a Request from a map the way the eager parser builds one off the wire: a header name or value may not contain CR or LF (an application- or test-constructed header gets no such check for free the way one read off the wire does -- this is where that rule lives for this path), and a name may not contain the colon that separates it from its value on the wire. Both are a real hazard, not a theoretical one, now that raw_headers is what a request's headers actually are: a value containing "\r\n" would be concatenated straight into the block below as a SECOND header line -- injection -- if it weren't rejected first.

### `fn parse(raw: bytes) -> result[Request, str]`

### `fn serialize(r: Response) -> bytes`

Assembled through a builder, not by `+`.  Every `+` on bytes allocates a new buffer and copies everything written so far into it, so building a response header by header re-copied the whole response once per header -- on every response the server sends. This is the same quadratic assembly `builder` was added to fix elsewhere; the stdlib's own HTTP path still had it.  A builder rather than a `[bytes]` and one `strings.join_bytes`: the list form was tried and measured slower, because a piece per header is an allocation per header before anything is joined.  This is the standalone/TLS path (`demo/main.sl` calls it directly) and `write`'s fallback for a response too large for its caller's arena. `write` itself does not call this when the response fits -- see `emit` below, which skips these allocations entirely.

### `fn wants_close(r: Request) -> bool`

### `fn read(c: &mut link, buf: wire, filled: int, deadline: until) -> result[Incoming, str]`

### `fn write(c: &mut link, r: Response, a: &mut arena, deadline: until) -> result[int, fault]`

serialize()'s GC allocations (~40 of them for a typical response, see serialize()'s own comment) replaced with two passes over the caller's own arena: size, then fill. If the response is larger than what's left of the arena, falls back to serialize() + send_bytes rather than letting a.wire(need) past capacity kill the task -- a slow response stays a slow response instead of becoming a dropped connection.

### `fn text_response(status: i32, status_text: str, content_type: str,`

### `fn ok_html(body: str) -> Response`

### `fn ok_css(body: str) -> Response`

### `fn ok_js(body: str) -> Response`

### `fn ok_json(body: str) -> Response`

### `fn ok_text(body: str) -> Response`

### `fn created_json(body: str) -> Response`

### `fn bad_request(msg: str) -> Response`

### `fn not_found() -> Response`

### `fn method_not_allowed() -> Response`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
