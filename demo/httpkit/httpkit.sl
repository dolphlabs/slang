// httpkit: a tiny hand-rolled HTTP/1.1 layer over the raw net
// package. slang has no string search/split builtins yet, so parsing
// works directly on `bytes` (indexing yields an int 0..255, and
// slicing/concatenation/equality all just work -- see the README's
// "bytes" section) and only converts to `str` once a field's exact
// boundaries are known.
//
// Deliberately minimal for a demo: no header parsing (Content-Length,
// chunked encoding, etc. are ignored), and it assumes one net.recv()
// captures the whole request -- true in practice for small JSON
// bodies over loopback, but not a guarantee a production parser could
// make.

pub struct Request {
    method: str,
    path: str,
    body: str,
}

pub struct Response {
    status: i32,
    status_text: str,
    content_type: str,
    body: bytes,
}

let CR: int = 13;
let LF: int = 10;
let SPACE: int = 32;

// Returns the index of the first occurrence of `target` in `b` at or
// after `from`, or -1 if not found. slang has no `break`/`continue`,
// so an early `return` from inside the loop stands in for `break`.
fn find_byte(b: bytes, from: int, target: int) -> int {
    let i = from;
    while i < len(b) {
        if b[i] == target {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

// Returns the index of the blank line (\r\n\r\n) separating headers
// from body, or -1 if there isn't one (yet, or ever -- e.g. a GET
// with no body).
fn find_blank_line(b: bytes) -> int {
    let i = 0;
    let n = len(b);
    while i + 3 < n {
        if b[i] == CR && b[i + 1] == LF && b[i + 2] == CR && b[i + 3] == LF {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

// Parses "METHOD path HTTP/1.1\r\n...headers...\r\n\r\nbody". Only
// method, path, and (if present) the raw body are extracted.
pub fn parse(raw: bytes) -> result[Request, str] {
    if len(raw) == 0 {
        return err("empty request");
    }
    let sp1 = find_byte(raw, 0, SPACE);
    if sp1 < 0 {
        return err("malformed request line: no method");
    }
    let sp2 = find_byte(raw, sp1 + 1, SPACE);
    if sp2 < 0 {
        return err("malformed request line: no path");
    }
    let method = to_str(raw[..sp1]);
    let path = to_str(raw[sp1 + 1..sp2]);

    let sep = find_blank_line(raw);
    let body = "";
    if sep >= 0 {
        let bodystart = sep + 4;
        if bodystart < len(raw) {
            body = to_str(raw[bodystart..]);
        }
    }

    return ok(Request { method: method, path: path, body: body });
}

pub fn text_response(status: i32, status_text: str, content_type: str,
                     body: str) -> Response {
    return Response {
        status: status,
        status_text: status_text,
        content_type: content_type,
        body: to_bytes(body)
    };
}

pub fn ok_html(body: str) -> Response {
    return text_response(200, "OK", "text/html; charset=utf-8", body);
}

pub fn ok_css(body: str) -> Response {
    return text_response(200, "OK", "text/css; charset=utf-8", body);
}

pub fn ok_js(body: str) -> Response {
    return text_response(200, "OK", "application/javascript; charset=utf-8",
                         body);
}

pub fn ok_json(body: str) -> Response {
    return text_response(200, "OK", "application/json; charset=utf-8", body);
}

pub fn created_json(body: str) -> Response {
    return text_response(201, "Created", "application/json; charset=utf-8",
                         body);
}

pub fn bad_request(msg: str) -> Response {
    let body = "{\"error\":\"" + msg + "\"}";
    return text_response(400, "Bad Request", "application/json; charset=utf-8",
                         body);
}

pub fn not_found() -> Response {
    return text_response(404, "Not Found", "text/plain; charset=utf-8",
                         "not found");
}

pub fn method_not_allowed() -> Response {
    return text_response(405, "Method Not Allowed",
                         "text/plain; charset=utf-8", "method not allowed");
}

// Full HTTP/1.0 response, headers + body, ready to hand to
// net.send/net.tls_send.
pub fn serialize(r: Response) -> bytes {
    let head = "HTTP/1.0 " + to_str(r.status) + " " + r.status_text + "\r\n"
        + "Content-Type: " + r.content_type + "\r\n"
        + "Content-Length: " + to_str(len(r.body)) + "\r\n"
        + "Connection: close\r\n"
        + "\r\n";
    return to_bytes(head) + r.body;
}
