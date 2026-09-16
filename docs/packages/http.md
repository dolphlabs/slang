# http

> Package http.

HTTP/1.1 over `link` / `wire` / `until` / `fault`. Parse a request
from `bytes`, or `read` from a connection into a caller-sized `wire`
(the max request size). `read` takes the unconsumed prefix length and
returns `Incoming` with leftover compacted to the front of the wire,
so one connection can carry many requests. `write` serializes a
`Response` through an arena. Headers are stored lowercased;
`header(req, name)` looks up case-insensitively. `Content-Length` is
honored; chunked `Transfer-Encoding` is rejected. `wants_close`
follows HTTP/1.1 keep-alive (and HTTP/1.0 close-by-default).

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

### `gc struct Incoming`

### `gc struct Response`

### `fn header(r: Request, name: str) -> opt[str]`

### `fn parse(raw: bytes) -> result[Request, str]`

### `fn serialize(r: Response) -> bytes`

### `fn wants_close(r: Request) -> bool`

### `fn read(c: &mut link, buf: wire, filled: int, deadline: until) -> result[Incoming, str]`

### `fn write(c: &mut link, r: Response, a: &mut arena, deadline: until) -> result[int, fault]`

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
