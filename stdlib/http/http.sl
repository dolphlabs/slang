import "builder";
import "byteutil";
import "strings";

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

// A header name, lowercased, in one allocation.
//
// This was `lower_ascii(to_str(raw[lo..hi]))`: a slice, a str, the bytes
// lower_ascii copied it back into, and the str it returned -- four
// allocations and three passes over the same few characters, per header,
// per request. `strings.from_bytes_lower` sizes the str once and
// lowercases as it copies.
//
// An interning table of the common names was tried first, to make the
// usual ones cost nothing at all. It needs the names as `bytes` to
// compare against, and a package-level `b"..."` is a by-value global that
// cannot be passed where a `bytes` is expected -- and building them per
// call is an allocation per comparison to save one per match. One
// allocation with no table beats it and is a quarter of the code.
fn header_name(raw: bytes, lo: int, hi: int) -> str {
    return strings.from_bytes_lower(raw, lo, hi);
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

// Digits only, and at most 18 of them. Unbounded, `n * 10 + d` wrapped:
// "Content-Length: 18446744073709551619" (2^64 + 3) framed as 3 bytes, and
// the rest of the body was read as the NEXT request -- a request-smuggling
// primitive against any proxy that computes the length correctly. 18
// digits cannot overflow a 64-bit int, and no real body is an exabyte.
fn parse_digits(s: str) -> result[int, str] {
    let b = to_bytes(s);
    if len(b) == 0 {
        return err("empty number");
    }
    if len(b) > 18 {
        return err("number too large");
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
    // One copy. This was `out = out + one_byte` for every byte, run on every
    // recv: quadratic in the request size, and so a denial of service -- a
    // single 200KB POST cost about fifteen seconds of CPU.
    return to_bytes(w[0..n]);
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
        let name = header_name(raw, i, colon);
        // Trim in place and slice once: `to_str(trim_ows(raw[a..b]))` cut
        // the range, cut it again, and copied it into a str -- three
        // allocations to move bytes that were already sitting there.
        let vlo = colon + 1;
        let vhi = eol;
        while vlo < vhi && is_ows(raw[vlo]) {
            vlo = vlo + 1;
        }
        while vhi > vlo && is_ows(raw[vhi - 1]) {
            vhi = vhi - 1;
        }
        let value = strings.from_bytes(raw, vlo, vhi);
        // The two headers that decide where a request ENDS may not repeat.
        // Other headers still take the last value, as before; these two
        // did too, so two disagreeing Content-Lengths were accepted with
        // the last silently winning -- while a proxy honouring the first
        // framed the same bytes differently. RFC 9112 section 6.3: reject.
        if (name == "content-length" || name == "transfer-encoding") &&
           has(headers, name) {
            return err("repeated " + name + " header");
        }
        headers[name] = value;
        i = eol + 2;
    }
    return ok(headers);
}

// ---- framing: where does this request's body end? ----------------------
//
// One function answers it for both parse() and read(), so they cannot
// disagree about the same bytes. Getting this wrong is not a parsing bug
// but a security one: if a front proxy and this server frame a request
// differently, the leftover bytes are read as a second request the proxy
// never saw -- request smuggling.
//
// Rules (RFC 9112 section 6):
//   - Transfer-Encoding: chunked, and nothing else. Any other coding, or a
//     list of codings, is refused rather than guessed at.
//   - Transfer-Encoding AND Content-Length together: refused. RFC 9112 lets
//     a server pick Transfer-Encoding; refusing is the choice that cannot
//     disagree with anyone.
//   - Transfer-Encoding in an HTTP/1.0 request: refused (section 6.1).
//   - Otherwise Content-Length, or no body.

// Chunk-size lines (with extensions) and the trailer section have their own
// ceilings: the buffer bounds the total, but without these one oversized
// line would be waited on until the buffer filled.
let MAX_CHUNK_LINE = 1024;
let MAX_TRAILERS = 8192;

gc struct Framing {
    complete: bool,
    end: int,      // offset one past the message, when complete
    need: int,     // total size when known up front (Content-Length), else -1
    body: bytes,
}

fn incomplete(need: int) -> Framing {
    return Framing { complete: false, end: 0, need: need, body: b"" };
}

fn hex_val(b: int) -> int {
    if b >= 48 && b <= 57 { return b - 48; }
    if b >= 97 && b <= 102 { return b - 87; }
    if b >= 65 && b <= 70 { return b - 55; }
    return -1;
}

// A line feed without its carriage return. Lenient parsers accept it and
// strict ones do not, which is exactly the disagreement smuggling needs.
fn bare_lf(raw: bytes, from: int, to: int) -> bool {
    let i = from;
    while i < to {
        if raw[i] == 10 && (i == 0 || raw[i - 1] != 13) {
            return true;
        }
        i = i + 1;
    }
    return false;
}

// Joined pairwise rather than appended one by one: a body of many tiny
// chunks would otherwise be copied once per chunk.
fn concat_parts(parts: [bytes]) -> bytes {
    if len(parts) == 0 {
        return b"";
    }
    let cur = parts;
    while len(cur) > 1 {
        let next: [bytes] = [];
        let k = 0;
        while k + 1 < len(cur) {
            push(next, cur[k] + cur[k + 1]);
            k = k + 2;
        }
        if k < len(cur) {
            push(next, cur[k]);
        }
        cur = next;
    }
    return cur[0];
}

fn scan_chunked(raw: bytes, start: int) -> result[Framing, str] {
    let i = start;
    let parts: [bytes] = [];
    while true {
        let eol = find_crlf(raw, i);
        if eol < 0 {
            if bare_lf(raw, i, len(raw)) {
                return err("bare LF in chunk size line");
            }
            if len(raw) - i > MAX_CHUNK_LINE {
                return err("chunk size line too long");
            }
            return ok(incomplete(-1));
        }
        if eol - i > MAX_CHUNK_LINE {
            return err("chunk size line too long");
        }
        if bare_lf(raw, i, eol) {
            return err("bare LF in chunk size line");
        }
        let size = 0;
        let digits = 0;
        let j = i;
        while j < eol && hex_val(raw[j]) >= 0 {
            // 15 hex digits cannot overflow; no chunk is anywhere near that
            if digits == 15 {
                return err("chunk size too large");
            }
            size = size * 16 + hex_val(raw[j]);
            digits = digits + 1;
            j = j + 1;
        }
        if digits == 0 {
            return err("malformed chunk size");
        }
        while j < eol && is_ows(raw[j]) {
            j = j + 1;
        }
        if j < eol && raw[j] != 59 {           // anything but ';' extensions
            return err("malformed chunk size");
        }
        i = eol + 2;

        if size == 0 {
            // Trailer fields, then an empty line. Read and discarded: merging
            // them into headers the handler already trusts would let a
            // trailer rewrite a header after it was checked.
            let tstart = i;
            while true {
                let teol = find_crlf(raw, i);
                if teol < 0 {
                    if bare_lf(raw, i, len(raw)) {
                        return err("bare LF in trailer");
                    }
                    if len(raw) - tstart > MAX_TRAILERS {
                        return err("trailers too large");
                    }
                    return ok(incomplete(-1));
                }
                if bare_lf(raw, i, teol) {
                    return err("bare LF in trailer");
                }
                if teol == i {
                    return ok(Framing { complete: true, end: i + 2, need: -1,
                                        body: concat_parts(parts) });
                }
                if teol + 2 - tstart > MAX_TRAILERS {
                    return err("trailers too large");
                }
                i = teol + 2;
            }
        }

        if i + size + 2 > len(raw) {
            return ok(incomplete(-1));
        }
        if raw[i + size] != 13 || raw[i + size + 1] != 10 {
            return err("chunk data not followed by CRLF");
        }
        push(parts, raw[i..i + size]);
        i = i + size + 2;
    }
    return err("unreachable");
}

fn frame(raw: bytes, headers: map[str]str, sep: int,
         version: str) -> result[Framing, str] {
    let body_start = sep + 4;
    if has(headers, "transfer-encoding") {
        let te = lower_ascii(headers["transfer-encoding"]);
        if te != "chunked" {
            // The value is NOT echoed: it is client-controlled, and servers
            // pass read errors to bad_request, which embeds the message in a
            // JSON string unescaped.
            return err("unsupported Transfer-Encoding");
        }
        if has(headers, "content-length") {
            return err("both Transfer-Encoding and Content-Length");
        }
        if version == "HTTP/1.0" {
            return err("Transfer-Encoding in an HTTP/1.0 request");
        }
        return scan_chunked(raw, body_start);
    }
    if !has(headers, "content-length") {
        return ok(Framing { complete: true, end: body_start, need: body_start,
                            body: b"" });
    }
    let clr = parse_digits(headers["content-length"]);
    guard let cl = clr else let e = err_of(clr) {
        return err("bad Content-Length: " + e);
    }
    let end = body_start + cl;
    if len(raw) < end {
        return ok(incomplete(end));
    }
    return ok(Framing { complete: true, end: end, need: end,
                        body: raw[body_start..end] });
}

gc struct Head {
    method: str,
    path: str,
    version: str,
    headers: map[str]str,
    sep: int,
}

fn parse_head(raw: bytes, sep: int) -> result[Head, str] {
    let line_end = find_crlf(raw, 0);
    if line_end < 0 || line_end > sep {
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
    // Trimmed by moving the bounds, not by slicing: same tolerance for
    // trailing OWS the trim_ows call here used to give, without the two
    // allocations it cost.
    let vlo2 = sp2 + 1;
    let vhi2 = line_end;
    while vlo2 < vhi2 && is_ows(raw[vlo2]) {
        vlo2 = vlo2 + 1;
    }
    while vhi2 > vlo2 && is_ows(raw[vhi2 - 1]) {
        vhi2 = vhi2 - 1;
    }
    let ver = strings.from_bytes(raw, vlo2, vhi2);
    if ver != "HTTP/1.0" && ver != "HTTP/1.1" {
        return err("unsupported HTTP version");
    }
    let hr = parse_headers(raw, line_end + 2, sep);
    guard let headers = hr else let e = err_of(hr) {
        return err("header: " + e);
    }
    return ok(Head { method: strings.from_bytes(raw, 0, sp1),
                     path: strings.from_bytes(raw, sp1 + 1, sp2),
                     version: ver, headers: headers, sep: sep });
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
    let sep = find_blank_line(raw);
    if sep < 0 {
        return err("missing header terminator");
    }
    let hr = parse_head(raw, sep);
    guard let head = hr else let e = err_of(hr) {
        return err(e);
    }
    let fr = frame(raw, head.headers, sep, head.version);
    guard let f = fr else let e = err_of(fr) {
        return err("body: " + e);
    }
    if !f.complete {
        return err("truncated body");
    }
    return ok(Request {
        method: head.method,
        path: head.path,
        version: head.version,
        headers: head.headers,
        body: f.body
    });
}

// Assembled through a builder, not by `+`.
//
// Every `+` on bytes allocates a new buffer and copies everything written
// so far into it, so building a response header by header re-copied the
// whole response once per header -- on every response the server sends.
// This is the same quadratic assembly `builder` was added to fix
// elsewhere; the stdlib's own HTTP path still had it.
pub fn serialize(r: Response) -> bytes {
    // Assembled through a builder, not by `+`.
    //
    // Every `+` on bytes allocates a new buffer and copies everything
    // written so far into it, so a response was re-copied once per header,
    // on every response the server sends -- the same quadratic assembly
    // `builder` exists to fix, still sitting in the stdlib's own HTTP
    // path.
    //
    // A builder rather than a `[bytes]` and one `strings.join_bytes`: the
    // list form was tried and measured slower, because a piece per header
    // means an allocation per header before anything is joined.
    //
    // This plus the single-allocation field extraction below is worth
    // ~40% on a keep-alive server with a 200-byte body and four headers:
    // medians of five interleaved A/B runs against the unmodified
    // package, 14.9k -> 20.8k req/s, and the new one won all five paired
    // rounds. The box swings ~20% run to run, so the pairing and the
    // medians are the claim, not any single number.
    let sb = builder.new_bytes();
    sb.write_str("HTTP/1.1 ");
    sb.write_str(to_str(r.status));
    sb.write_str(" ");
    sb.write_str(r.status_text);
    sb.write_str("\r\n");
    for k, v in r.headers {
        if k != "content-length" && k != "connection" {
            sb.write_str(k);
            sb.write_str(": ");
            sb.write_str(v);
            sb.write_str("\r\n");
        }
    }
    let conn = "keep-alive";
    if has(r.headers, "connection") {
        conn = r.headers["connection"];
    }
    sb.write_str("Content-Length: ");
    sb.write_str(to_str(len(r.body)));
    sb.write_str("\r\nConnection: ");
    sb.write_str(conn);
    sb.write_str("\r\n\r\n");
    sb.write(r.body);
    return sb.finish();
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

pub fn read(c: &mut link, buf: wire, filled: int, deadline: until) -> result[Incoming, str] {
    while true {
        if filled > 0 {
            let raw = copy_wire(buf, filled);
            let sep = find_blank_line(raw);
            if sep >= 0 {
                let hr = parse_head(raw, sep);
                guard let head = hr else let e = err_of(hr) {
                    return err(e);
                }
                let fr = frame(raw, head.headers, sep, head.version);
                guard let f = fr else let e = err_of(fr) {
                    return err("body: " + e);
                }
                if f.need > len(buf) {
                    return err("request too large for buffer");
                }
                if f.complete {
                    let req = Request {
                        method: head.method,
                        path: head.path,
                        version: head.version,
                        headers: head.headers,
                        body: f.body
                    };
                    // Pipelined bytes after this request stay for the next.
                    let rest = compact_wire(buf, f.end, filled);
                    return ok(Incoming { req: req, filled: rest });
                }
            }
        }
        if filled >= len(buf) {
            return err("request too large for buffer");
        }
        let tail = buf[filled..];
        let rr = c.recv(tail, deadline);
        guard let n = rr else let e = err_of(rr) {
            return err("recv: " + to_str(e));
        }
        if n == 0 {
            if filled == 0 {
                return err("connection closed");
            }
            return err("truncated request");
        }
        filled = filled + n;
    }
}

pub fn write(c: &mut link, r: Response, a: &mut arena, deadline: until) -> result[int, fault] {
    let raw = serialize(r);
    return c.send_bytes(raw, deadline);
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
