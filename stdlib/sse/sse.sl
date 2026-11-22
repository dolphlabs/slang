// Server-Sent Events (the HTML spec's text/event-stream): a server pushing
// events to a browser's EventSource over one long HTTP response, and a
// client reading such a stream.
//
//     import "sse";
//
//     // server, on a link after reading the request:
//     c.send_bytes(sse.head(), deadline);
//     c.send_bytes(sse.event("tick", "{\"n\":1}", "1"), deadline);
//     c.send_bytes(sse.comment("keep-alive"), deadline);   // every ~15 s
//
//     // client:
//     let p = sse.parser();
//     for e in sse.feed(p, chunk) { println(e.kind + ": " + e.data); }
//
// The response has no Content-Length: the stream ends when the server
// closes the connection. Proxies that buffer responses are told not to
// (X-Accel-Buffering) so events are not held back.

import "strings";

// The response head for an event stream.
pub fn head() -> bytes {
    return to_bytes("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\n" +
                    "Cache-Control: no-cache\r\nConnection: keep-alive\r\n" +
                    "X-Accel-Buffering: no\r\n\r\n");
}

// One event. kind "" means the default "message"; id "" sends none. Data
// with newlines becomes several data lines, as the format requires.
pub fn event(kind: str, data: str, id: str) -> bytes {
    let out: [str] = [];
    if len(kind) > 0 { push(out, "event: " + one_line(kind) + "\n"); }
    if len(id) > 0 { push(out, "id: " + one_line(id) + "\n"); }
    let d = strings.replace(data, "\r\n", "\n");
    d = strings.replace(d, "\r", "\n");
    for line in strings.split(d, "\n") {
        push(out, "data: " + line + "\n");
    }
    push(out, "\n");
    return to_bytes(strings.join(out, ""));
}

// A comment line, which clients ignore: a heartbeat that keeps idle
// proxies from closing the stream.
pub fn comment(text: str) -> bytes {
    return to_bytes(": " + one_line(text) + "\n\n");
}

// Tells the client how long to wait before reconnecting.
pub fn retry(ms: int) -> bytes {
    return to_bytes("retry: " + to_str(ms) + "\n\n");
}

pub struct Event {
    kind: str,      // "message" unless the event named one
    data: str,
    id: str,        // the last event id seen (what to send as Last-Event-ID)
}

pub gc struct Parser {
    buf: str,
    started: bool,
    kind: str,
    data: [str],
    has_data: bool,
    last_id: str,
    retry_ms: int,
}

pub fn parser() -> Parser {
    let d: [str] = [];
    return Parser { buf: "", started: false, kind: "", data: d, has_data: false,
                    last_id: "", retry_ms: -1 };
}

// The events completed by the next bytes of the stream.
pub fn feed(p: Parser, chunk: bytes) -> [Event] {
    let out: [Event] = [];
    p.buf = p.buf + to_str(chunk);
    if !p.started && len(p.buf) >= 3 {
        p.started = true;
        if strings.has_prefix(p.buf, "\u{feff}") { p.buf = strings.slice(p.buf, 3, len(p.buf)); }
    }
    while true {
        let cr = strings.find(p.buf, "\r");
        let lf = strings.find(p.buf, "\n");
        let end = lf;
        if cr >= 0 && (lf < 0 || cr < lf) { end = cr; }
        if end < 0 { break; }
        // a CR at the very end may be the first half of CRLF: wait
        if end == cr && cr == len(p.buf) - 1 { break; }
        let line = strings.slice(p.buf, 0, end);
        let skip = 1;
        if end == cr && cr + 1 < len(p.buf) && strings.slice(p.buf, cr + 1, cr + 2) == "\n" { skip = 2; }
        p.buf = strings.slice(p.buf, end + skip, len(p.buf));
        line_of(p, line, out);
    }
    return out;
}

// The reconnection delay the server last asked for, or -1.
pub fn retry_ms(p: Parser) -> int {
    return p.retry_ms;
}

fn line_of(p: Parser, line: str, out: [Event]) {
    if len(line) == 0 {
        if p.has_data {
            let kind = p.kind;
            if len(kind) == 0 { kind = "message"; }
            push(out, Event { kind: kind, data: strings.join(p.data, "\n"), id: p.last_id });
        }
        let empty: [str] = [];
        p.data = empty;
        p.has_data = false;
        p.kind = "";
        return;
    }
    if strings.has_prefix(line, ":") { return; }
    let c = strings.find(line, ":");
    let field = line;
    let value = "";
    if c >= 0 {
        field = strings.slice(line, 0, c);
        value = strings.slice(line, c + 1, len(line));
        if strings.has_prefix(value, " ") { value = strings.slice(value, 1, len(value)); }
    }
    if field == "data" {
        push(p.data, value);
        p.has_data = true;
    } else if field == "event" {
        p.kind = value;
    } else if field == "id" {
        // an id containing NUL is ignored, as the spec says (looked for
        // in the bytes: a str literal cannot hold a NUL to compare with)
        if !has_nul(value) { p.last_id = value; }
    } else if field == "retry" {
        let n = to_int(value) ?? -1;
        if n >= 0 && all_digits(value) { p.retry_ms = n; }
    }
}

fn has_nul(s: str) -> bool {
    let b = to_bytes(s);
    for i in 0..len(b) {
        if (b[i] as int) == 0 { return true; }
    }
    return false;
}

fn all_digits(s: str) -> bool {
    let b = to_bytes(s);
    if len(b) == 0 { return false; }
    for i in 0..len(b) {
        let c = b[i] as int;
        if c < 48 || c > 57 { return false; }
    }
    return true;
}

fn one_line(s: str) -> str {
    return strings.replace(strings.replace(s, "\r", ""), "\n", "");
}
