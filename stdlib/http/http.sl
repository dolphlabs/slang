import "byteutil";

pub gc struct Request {
    method: str,
    path: str,
    version: str,
    headers: map[str]str,
    body: bytes,
}

pub gc struct Incoming {
    req: Request,
    filled: int,
}

pub gc struct Response {
    status: i32,
    status_text: str,
    headers: map[str]str,
    body: bytes,
}

fn lower_byte(b: int) -> int {
    if b >= 65 && b <= 90 {
        return b + 32;
    }
    return b;
}

fn lower_ascii(s: str) -> str {
    let b = to_bytes(s);
    let i = 0;
    while i < len(b) {
        b[i] = lower_byte(b[i]);
        i = i + 1;
    }
    return to_str(b);
}

fn is_ows(b: int) -> bool {
    return b == 32 || b == 9;
}

fn find_crlf(b: bytes, from: int) -> int {
    let i = from;
    while i + 1 < len(b) {
        if b[i] == 13 && b[i + 1] == 10 {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

fn find_blank_line(b: bytes) -> int {
    let i = 0;
    let n = len(b);
    while i + 3 < n {
        if b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10 {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

fn parse_digits(s: str) -> result[int, str] {
    let b = to_bytes(s);
    if len(b) == 0 {
        return err("empty number");
    }
    let n = 0;
    let i = 0;
    while i < len(b) {
        let d = b[i];
        if d < 48 || d > 57 {
            return err("bad number");
        }
        n = n * 10 + (d - 48);
        i = i + 1;
    }
    return ok(n);
}

fn trim_ows(b: bytes) -> bytes {
    let lo = 0;
    let hi = len(b);
    while lo < hi && is_ows(b[lo]) {
        lo = lo + 1;
    }
    while hi > lo && is_ows(b[hi - 1]) {
        hi = hi - 1;
    }
    return b[lo..hi];
}

fn copy_wire(w: wire, n: int) -> bytes {
    let out = b"";
    let i = 0;
    while i < n {
        out = out + to_le(w[i])[0..1];
        i = i + 1;
    }
    return out;
}

fn fill_wire(dst: wire, src: bytes) {
    let i = 0;
    for b in src {
        dst[i] = b;
        i = i + 1;
    }
}

fn recv_fault(deadline: until) -> fault {
    if until_hit(deadline) {
        return fault_timeout();
    }
    return fault_io();
}

fn parse_headers(raw: bytes, start: int, sep: int) -> result[map[str]str, str] {
    let headers: map[str]str = {};
    let i = start;
    while i < sep {
        let eol = find_crlf(raw, i);
        if eol < 0 || eol > sep {
            return err("malformed header");
        }
        if eol == i {
            break;
        }
        if is_ows(raw[i]) {
            return err("folded header");
        }
        let colon = byteutil.find(raw, i, 58);
        if colon < 0 || colon >= eol || colon == i {
            return err("malformed header");
        }
        let name = lower_ascii(to_str(raw[i..colon]));
        let value = to_str(trim_ows(raw[colon + 1..eol]));
        headers[name] = value;
        i = eol + 2;
    }
    return ok(headers);
}

fn rejects_transfer(headers: map[str]str) -> bool {
    if !has(headers, "transfer-encoding") {
        return false;
    }
    return lower_ascii(headers["transfer-encoding"]) != "identity";
}

fn body_need(headers: map[str]str, sep: int) -> result[int, str] {
    if !has(headers, "content-length") {
        return ok(sep + 4);
    }
    let clr = parse_digits(headers["content-length"]);
    guard let cl = clr else {
        return err("bad Content-Length");
    }
    if cl < 0 {
        return err("bad Content-Length");
    }
    return ok(sep + 4 + cl);
}

pub fn header(r: Request, name: str) -> opt[str] {
    let k = lower_ascii(name);
    if has(r.headers, k) {
        return some(r.headers[k]);
    }
    return none;
}

pub fn parse(raw: bytes) -> result[Request, str] {
    if len(raw) == 0 {
        return err("empty request");
    }
    let line_end = find_crlf(raw, 0);
    if line_end < 0 {
        return err("malformed request line");
    }
    let sp1 = byteutil.find(raw, 0, 32);
    if sp1 < 0 || sp1 >= line_end {
        return err("malformed request line: no method");
    }
    let sp2 = byteutil.find(raw, sp1 + 1, 32);
    if sp2 < 0 || sp2 >= line_end {
        return err("malformed request line: no path");
    }
    if sp1 == 0 || sp2 == sp1 + 1 {
        return err("malformed request line");
    }
    let method = to_str(raw[0..sp1]);
    let path = to_str(raw[sp1 + 1..sp2]);
    let ver = to_str(trim_ows(raw[sp2 + 1..line_end]));
    if ver != "HTTP/1.0" && ver != "HTTP/1.1" {
        return err("unsupported HTTP version");
    }

    let sep = find_blank_line(raw);
    if sep < 0 {
        return err("missing header terminator");
    }

    let hr = parse_headers(raw, line_end + 2, sep);
    guard let headers = hr else {
        return err("malformed header");
    }
    if rejects_transfer(headers) {
        return err("chunked encoding is not supported");
    }

    let nr = body_need(headers, sep);
    guard let need = nr else {
        return err("bad Content-Length");
    }
    if need > len(raw) {
        return err("truncated body");
    }
    let body = raw[sep + 4..need];

    return ok(Request {
        method: method,
        path: path,
        version: ver,
        headers: headers,
        body: body
    });
}

pub fn serialize(r: Response) -> bytes {
    let head = "HTTP/1.1 " + to_str(r.status) + " " + r.status_text + "\r\n";
    for k, v in r.headers {
        if k != "content-length" && k != "connection" {
            head = head + k + ": " + v + "\r\n";
        }
    }
    let conn = "keep-alive";
    if has(r.headers, "connection") {
        conn = r.headers["connection"];
    }
    head = head + "Content-Length: " + to_str(len(r.body)) + "\r\n"
        + "Connection: " + conn + "\r\n\r\n";
    return to_bytes(head) + r.body;
}

fn compact_wire(buf: wire, used: int, filled: int) -> int {
    if used <= 0 {
        return filled;
    }
    let n = filled - used;
    let i = 0;
    while i < n {
        buf[i] = buf[used + i];
        i = i + 1;
    }
    return n;
}

pub fn wants_close(r: Request) -> bool {
    let c = header(r, "connection");
    if r.version == "HTTP/1.0" {
        guard let v = c else {
            return true;
        }
        return lower_ascii(v) != "keep-alive";
    }
    guard let v = c else {
        return false;
    }
    return lower_ascii(v) == "close";
}

pub fn read(c: &mut link, buf: wire, filled: int, deadline: until) -> result[Incoming, fault] {
    while true {
        if filled > 0 {
            let raw = copy_wire(buf, filled);
            let sep = find_blank_line(raw);
            if sep >= 0 {
                let line_end = find_crlf(raw, 0);
                if line_end < 0 {
                    return err(fault_io());
                }
                let hr = parse_headers(raw, line_end + 2, sep);
                guard let headers = hr else {
                    return err(fault_io());
                }
                if rejects_transfer(headers) {
                    return err(fault_io());
                }
                let nr = body_need(headers, sep);
                guard let need = nr else {
                    return err(fault_io());
                }
                if need > len(buf) {
                    return err(fault_io());
                }
                if filled >= need {
                    let parsed = parse(raw);
                    guard let req = parsed else {
                        return err(fault_io());
                    }
                    let rest = compact_wire(buf, need, filled);
                    return ok(Incoming { req: req, filled: rest });
                }
            }
        }
        if filled >= len(buf) {
            return err(fault_io());
        }
        let tail = buf[filled..];
        let rr = c.recv(tail, deadline);
        guard let n = rr else {
            return err(recv_fault(deadline));
        }
        if n == 0 {
            if filled == 0 {
                return err(fault_closed());
            }
            return err(fault_io());
        }
        filled = filled + n;
    }
}

pub fn write(c: &mut link, r: Response, a: &mut arena, deadline: until) -> result[int, fault] {
    let raw = serialize(r);
    let w = a.wire(len(raw));
    fill_wire(w, raw);
    return c.send(w, deadline);
}

pub fn text_response(status: i32, status_text: str, content_type: str,
                     body: str) -> Response {
    let headers: map[str]str = {};
    headers["content-type"] = content_type;
    return Response {
        status: status,
        status_text: status_text,
        headers: headers,
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

pub fn ok_text(body: str) -> Response {
    return text_response(200, "OK", "text/plain; charset=utf-8", body);
}

pub fn created_json(body: str) -> Response {
    return text_response(201, "Created", "application/json; charset=utf-8",
                         body);
}

pub fn bad_request(msg: str) -> Response {
    return text_response(400, "Bad Request", "application/json; charset=utf-8",
                         "{\"error\":\"" + msg + "\"}");
}

pub fn not_found() -> Response {
    return text_response(404, "Not Found", "text/plain; charset=utf-8",
                         "not found");
}

pub fn method_not_allowed() -> Response {
    return text_response(405, "Method Not Allowed",
                         "text/plain; charset=utf-8", "method not allowed");
}
