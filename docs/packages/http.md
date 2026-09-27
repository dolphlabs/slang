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

### `gc struct WireFrame`

`read` couples two things that only sometimes belong together: filling the caller's buffer and framing what's in it. serve_conn needs the split for frame dispatch: read_frame frames with the same scans/errors/rules as read, but returns the parsed head (method/path strs, header block, body) instead of a Request -- so the router matches on strs with no raw copy, no rescan, no second slice. Offsets stay for Frame callers and tests; the serve path does not use them.

### `gc struct Incoming`

### `gc struct Frame`

The request WITHOUT materialising method/path/version strs: framing offsets only. `read`/`serve` use this when they only route on the raw path bytes (see path_matches below); `parse` keeps returning strs for callers that actually need them.

### `gc struct Response`

### `fn header(r: Request, name: str) -> opt[str]`

### `fn header_or(r: Request, name: str, fallback: str) -> str`

header()'s two real call sites (Ctx.header in zokor, the WebSocket handshake) are both `header(...) ?? fallback` already -- this is that, without the opt allocation `??` unwraps.

### `fn headers(r: Request) -> map[str]str`

Every header a request carries, as a map -- built fresh on each call by scanning raw_headers once. Nothing in either repo iterates a request's headers today (confirmed by grep), which is what makes "built on demand" the right default over a cached field: a cache nothing reads is pure cost. Walks the same line shape scan_headers does, for a different reason (that one validates and extracts two offsets; this one assumes an already-valid block and extracts every name and value) -- kept as two functions rather than one parameterized by what to do with each line, which would obscure both to save repeating six lines.

### `fn request(method: str, path: str, version: str,`

Builds a Request from a map the way the eager parser builds one off the wire: a header name or value may not contain CR or LF (an application- or test-constructed header gets no such check for free the way one read off the wire does -- this is where that rule lives for this path), and a name may not contain the colon that separates it from its value on the wire. Both are a real hazard, not a theoretical one, now that raw_headers is what a request's headers actually are: a value containing "\r\n" would be concatenated straight into the block below as a SECOND header line -- injection -- if it weren't rejected first.

### `fn parse_frame(raw: bytes) -> result[Frame, str]`

Framing offsets for one request inside `raw`, with NOTHING materialised: no method/path/version strs, no header copies. The request line is validated (two spaces, HTTP/1.x token); the header block is validated by scan_headers; the body is framed by frame(). Callers that need strs (logging, tests) use parse(); the server path matches/routes directly on these offsets -- see path_matches and method_is below -- so the ~10 framing strs per request never exist.

### `fn method_is(raw: bytes, f: Frame, want: str) -> bool`

Is this frame's method exactly `want` (e.g. "GET"), compared in place -- no method str is ever built. Takes a line_end int (not a Frame) so both Frame and WireFrame callers share it.

### `fn method_is_at(raw: bytes, line_end: int, want: str) -> bool`

### `fn path_is(raw: bytes, f: Frame, want: str) -> bool`

Is this frame's path exactly `want` (bytes compared in place, query string ignored -- matches path.strip_query semantics)? No path str. The two hot paths (`/` and `/users/`-prefixed) compare inline with no to_bytes at all; anything else falls through to the general compare, which still costs one to_bytes of `want`. Route fpaths could precompute that bytes once at registration -- the next step if `/users/:id` still shows hot after this.

### `fn path_is_at(raw: bytes, line_end: int, want: str) -> bool`

### `fn path_param(raw: bytes, f: Frame, prefix: str) -> str`

The :id in "/users/:id" for a frame already known to match that shape -- the ONE allocation the params map used to cost per route scanned. Returns "" when the shape does not match.

### `fn path_param_at(raw: bytes, line_end: int, prefix: str) -> str`

### `fn frame_method(raw: bytes, f: Frame) -> str`

The method bytes as a str: the ONE framing str frame dispatch needs (to map to the Method enum). Everything else matches in place; this is 1 alloc where parse() spent ~10. Takes line_end so Frame and WireFrame share it.

### `fn frame_method_at(raw: bytes, line_end: int) -> str`

### `fn frame_request(raw: bytes, f: Frame) -> Request`

The full Request for a frame, built ONCE for the route that runs: method/path/version strs, raw_headers slice, body slice. serve() callers already hold one; serve_frame builds one -- never both. Takes explicit offsets so Frame and WireFrame share it.

### `fn frame_request_at(raw: bytes, line_end: int, head_end: int,`

### `fn frame_version(f: Frame) -> int`

### `fn frame_body(raw: bytes, f: Frame) -> bytes`

### `fn wire_request(f: WireFrame) -> Request`

The Request for a WireFrame: method/path already parsed, body already sliced -- no offsets, no raw, no second copy. headers rides along (one block copy, same as read -- the wire is compacted before return, so there is nothing to materialise from later). version comes from the flag (no version str is stored).

### `fn frame_raw_headers(raw: bytes, f: Frame, line_end: int) -> bytes`

### `fn parse(raw: bytes) -> result[Request, str]`

### `fn resp_headers(r: Response) -> map[str]str`

### `fn resp_header(r: Response, name: str) -> opt[str]`

### `fn has_resp_header(r: Response, name: str) -> bool`

### `fn serialize(r: Response) -> bytes`

### `fn serialize_builder(r: Response) -> bytes`

The old builder path, kept for the differential test: must stay byte-identical to serialize_sized() above for every shape.

### `fn serialize_sized(r: Response) -> bytes`

Serialize with a handful of allocations, not ~40: size the response first (status line + headers + framing + body, all cheap integer arithmetic over lengths -- see emit_len below), allocate exactly that many bytes with strings.bytes_zero (one header plus one buffer -- no throwaway str), then fill by slice assignment. The old builder path stays below as serialize_builder for the differential test; this is what `serialize` and `write`'s fallback call, so an oversized response costs a few allocations instead of ~40.  The remaining handful is load-bearing, not waste: one to_bytes per fill_str piece (the str->bytes copy the compiler cannot fuse), one filtered-extra list, and the response_conn scan's own line strs. Counting them is what keeps this honest -- see the probe notes.

### `fn escape_json_bytes(msg: bytes) -> bytes`

The escaped form of `msg` as bytes, for a caller that already holds bytes and wants the quoted payload without a str in between.

### `fn with_headers(r: Response, lines: [str]) -> Response`

### `fn with_header(r: Response, name: str, value: str) -> Response`

### `fn without_header(r: Response, name: str) -> Response`

### `fn wants_close(r: Request) -> bool`

### `fn version_flag_of(v: str) -> int`

The int-flag twin, for callers holding a version str rather than a Head (read_frame's WireFrame.version). Same rules; the block is passed explicitly because there is no Head in scope.

### `fn read_frame(c: &mut link, buf: wire, filled: int,`

read_frame: read's framing, plus the parsed head the router matches on. Implemented INSIDE read's loop shape (not as read-plus-copy): read compacts the buffer before returning, so after read there is no head left to copy -- buf[0..filled] is the NEXT request. This duplicates read's loop deliberately (same scans, same errors, same close rules), and the duplication is the contract: any change to read's framing must land here too.  What differs from read: on a complete frame the method/path strs and the header block + body are COPIED OUT of the wire ONCE -- the same strs + copies read already pays (hd2.method/path, hd2.headers, fm.body) -- and NO separate message copy is made. The old shape did to_bytes(buf[0..end]) PLUS parse_frame over the copy PLUS wants_close_scan over the copy: a full second framing pass and a whole-message copy per request. Now the WireFrame carries what the router needs directly: method/path strs for the enum + Request build, headers/body slices for the Ctx. Routing matches on strs (==), never on raw bytes -- no path_is_at rescan, no per-route to_bytes. The message copy is gone entirely.  Chunked bodies: fm.body IS the reassembled copy (one alloc the old path also spent); the WireFrame body is that copy directly.

### `fn read(c: &mut link, buf: wire, filled: int, deadline: until) -> result[Incoming, str]`

### `gc struct StaticBody`

serialize()'s GC allocations (~40 of them for a typical response, see serialize()'s own comment) replaced with two passes over the caller's own arena: size, then fill. If the response is larger than what's left of the arena, falls back to serialize() + send_bytes rather than letting a.wire(need) past capacity kill the task -- a slow response stays a slow response instead of becoming a dropped connection.  Responses with exactly the `text_response` shape (one content-type, nothing else) take the fixed fast path above: no map iteration, no integer str, no intermediate bytes. Anything else uses the general `emit` below, unchanged. A static route's answer: status, content type, and body -- no Response struct, no extra list, nothing to shape-check. serve_conn gets one from serve_static and hands it straight to write_static, which sends the PREBUILT keep-alive rendering (assembled once at registration -- see static_render below) with one wire alloc and one memcpy. The static snapshot lives on the Route (see router.sl); this is just the per-request view of it.

### `fn write_static(c: &mut link, b: StaticBody, a: &mut arena,`

The static emit: the keep-alive rendering is prebuilt, not emitted. Hot path (HTTP/1.1 keep-alive, which is every wrk/ab request): one wire, one memcpy, one send -- no probe pass, no Response struct, no map, no integer str, no per-piece puts. The close variant (HTTP/1.0, Connection: close) is rare and pays the emit cost below; it never touches the hot path.

### `fn static_render(status: i32, content_type: str, body: bytes) -> bytes`

The keep-alive rendering, assembled ONCE at registration: status line, one content-type, content-length, connection, blank line, body -- the exact bytes write_static memcpys per request. status_text_of covers the statuses static routes return; the fallback ("OK") matches write_static's own close variant above, so the two can never disagree on a reason phrase.

### `fn write(c: &mut link, r: Response, a: &mut arena, deadline: until) -> result[int, fault]`

### `fn text_response_bytes(status: i32, status_text: str, content_type: str,`

`text_response` with a BYTES body: same shape, no `to_bytes` copy. The hot path (zokor's JSON renderers, static bodies) already holds bytes; forcing them through str and back cost a full copy plus the literal's own allocation on every response.

### `fn text_response(status: i32, status_text: str, content_type: str,`

### `fn ok_html(body: str) -> Response`

### `fn ok_css(body: str) -> Response`

### `fn ok_js(body: str) -> Response`

### `fn ok_json(body: str) -> Response`

### `fn ok_text(body: str) -> Response`

### `fn created_json(body: str) -> Response`

### `fn bad_request(msg: str) -> Response`

### `fn bad_request_bytes(msg: bytes) -> Response`

`bad_request` with a BYTES message: same envelope, no `to_bytes` round-trip. The message still rides inside a JSON string, so it is escaped the same way -- see `escape_json_into` below.

### `fn not_found() -> Response`

### `fn method_not_allowed() -> Response`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
