# sse

> Package sse.

Server-Sent Events: a server pushing events to a browser's `EventSource`
over one long response, and a client reading such a stream.

```slang
import "sse";

// server, on a link after reading the request
c.send_bytes(sse.head(), deadline);
c.send_bytes(sse.event("tick", "{\"n\":1}", "1"), deadline);
c.send_bytes(sse.comment("keep-alive"), deadline);     // every ~15 seconds

// client
let p = sse.parser();
for e in sse.feed(p, chunk) { println(e.kind + ": " + e.data); }
```

`head()` sends no Content-Length (the stream ends when the server closes
the connection) and tells buffering proxies not to hold events back.
`event` splits multi-line data into data lines. The parser follows the
HTML specification: CR, LF and CRLF line endings even when split between
chunks, the last event id (for `Last-Event-ID` on reconnect), `retry_ms`,
comments, and a leading byte-order mark.

## API

### `fn head() -> bytes`

The response head for an event stream.

### `fn event(kind: str, data: str, id: str) -> bytes`

One event. kind "" means the default "message"; id "" sends none. Data with newlines becomes several data lines, as the format requires.

### `fn comment(text: str) -> bytes`

A comment line, which clients ignore: a heartbeat that keeps idle proxies from closing the stream.

### `fn retry(ms: int) -> bytes`

Tells the client how long to wait before reconnecting.

### `struct Event`

### `gc struct Parser`

### `fn parser() -> Parser`

### `fn feed(p: Parser, chunk: bytes) -> [Event]`

The events completed by the next bytes of the stream.

### `fn retry_ms(p: Parser) -> int`

The reconnection delay the server last asked for, or -1.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
