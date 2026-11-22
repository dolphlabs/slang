// multipart/form-data (RFC 7578): file uploads and forms, read as a
// stream so a large upload never has to fit in memory, and written for
// uploads from a client.
//
//     import "multipart";
//
//     let b = multipart.boundary_of(content_type) ?? "";
//     let p = multipart.parser(b);
//     while reading {
//         let er = multipart.feed(p, chunk);           // as bytes arrive
//         guard let evs = er else { /* 400 */ }
//         for e in evs {
//             if e.kind == multipart.PART { /* e.part: name, filename, ... */ }
//             else if e.kind == multipart.DATA { /* e.data: the next bytes */ }
//             else if e.kind == multipart.PART_END { ... }
//         }
//     }
//     multipart.finish(p)                              // err if cut short
//
// Part data comes out as it arrives, in pieces of any size; the parser
// holds back only the bytes that might be the start of a boundary. A
// part's headers are limited to max_header_bytes (8 KB) and the number of
// parts to max_parts (1000), so a hostile body cannot make it buffer
// without bound.

import "builder";
import "byteutil";
import "strings";

pub let PART = 0;       // a part starts: see Event.part
pub let DATA = 1;       // part data: Event.data
pub let PART_END = 2;   // the current part is complete
pub let DONE = 3;       // the closing boundary: nothing more

pub struct Part {
    name: str,
    filename: str,        // "" for a plain field
    content_type: str,    // "text/plain" when the part gives none
    headers: map[str]str, // all of them, names lower-cased
}

pub struct Event {
    kind: int,
    part: Part,
    data: bytes,
}

pub gc struct Parser {
    delim: bytes,          // CRLF "--" boundary
    buf: bytes,
    state: int,
    parts: int,
    max_header_bytes: int,
    max_parts: int,
}

let S_PREAMBLE = 0;
let S_AFTER_DELIM = 1;
let S_HEADERS = 2;
let S_BODY = 3;
let S_DONE = 4;

// The boundary parameter of a multipart Content-Type.
pub fn boundary_of(content_type: str) -> opt[str] {
    let lower = strings.to_lower(content_type);
    if !strings.has_prefix(strings.trim(lower), "multipart/") { return none; }
    let at = strings.find(lower, "boundary=");
    if at < 0 { return none; }
    let v = strings.slice(content_type, at + 9, len(content_type));
    let semi = strings.find(v, ";");
    if semi >= 0 { v = strings.slice(v, 0, semi); }
    v = strings.trim(v);
    if strings.has_prefix(v, "\"") && strings.has_suffix(v, "\"") && len(v) >= 2 {
        v = strings.slice(v, 1, len(v) - 1);
    }
    if len(v) == 0 || len(v) > 70 { return none; }
    return some(v);
}

pub fn parser(boundary: str) -> Parser {
    // the body may start with the boundary itself (no CRLF before it):
    // seed the buffer with one so the first delimiter matches like the rest
    return Parser { delim: to_bytes("\r\n--" + boundary), buf: b"\r\n", state: S_PREAMBLE,
                    parts: 0, max_header_bytes: 8192, max_parts: 1000 };
}

// Takes the next bytes of the body; returns what they completed.
pub fn feed(p: Parser, chunk: bytes) -> result[[Event], str] {
    let out: [Event] = [];
    if p.state == S_DONE { return ok(out); }
    p.buf = p.buf + chunk;
    while true {
        if p.state == S_PREAMBLE {
            let i = find(p.buf, p.delim, 0);
            if i < 0 {
                // keep only what could be the start of the delimiter
                let keep = len(p.delim) - 1;
                if len(p.buf) > keep { p.buf = p.buf[len(p.buf) - keep..]; }
                return ok(out);
            }
            p.buf = p.buf[i + len(p.delim)..];
            p.state = S_AFTER_DELIM;
        } else if p.state == S_AFTER_DELIM {
            if len(p.buf) < 2 { return ok(out); }
            if p.buf[0..2] == b"--" {
                p.state = S_DONE;
                p.buf = b"";
                push(out, ev(DONE, b""));
                return ok(out);
            }
            // transport padding (spaces, tabs) may sit before the CRLF
            let k = 0;
            while k < len(p.buf) && ((p.buf[k] as int) == 32 || (p.buf[k] as int) == 9) { k = k + 1; }
            if k + 2 > len(p.buf) {
                if k > 64 { return err("multipart: bad boundary line"); }
                return ok(out);
            }
            if p.buf[k..k + 2] != b"\r\n" { return err("multipart: bad boundary line"); }
            p.buf = p.buf[k + 2..];
            p.state = S_HEADERS;
        } else if p.state == S_HEADERS {
            let end = find(p.buf, b"\r\n\r\n", 0);
            let empty_head = len(p.buf) >= 2 && p.buf[0..2] == b"\r\n";
            if end < 0 && !empty_head {
                if len(p.buf) > p.max_header_bytes { return err("multipart: part headers too long"); }
                return ok(out);
            }
            let head = b"";
            let rest = 2;
            if !empty_head {
                head = p.buf[0..end];
                rest = end + 4;
            }
            if len(head) > p.max_header_bytes { return err("multipart: part headers too long"); }
            p.parts = p.parts + 1;
            if p.parts > p.max_parts { return err("multipart: too many parts"); }
            let pr = parse_part_head(to_str(head));
            guard let part = pr else let e = err_of(pr) { return err(e); }
            let e = ev(PART, b"");
            e.part = part;
            push(out, e);
            p.buf = p.buf[rest..];
            p.state = S_BODY;
        } else if p.state == S_BODY {
            let i = find(p.buf, p.delim, 0);
            if i < 0 {
                let safe = len(p.buf) - (len(p.delim) - 1);
                if safe > 0 {
                    push(out, ev(DATA, p.buf[0..safe]));
                    p.buf = p.buf[safe..];
                }
                return ok(out);
            }
            if i > 0 { push(out, ev(DATA, p.buf[0..i])); }
            push(out, ev(PART_END, b""));
            p.buf = p.buf[i + len(p.delim)..];
            p.state = S_AFTER_DELIM;
        } else {
            return ok(out);
        }
    }
    return ok(out);
}

// The body has ended: an error unless the closing boundary was seen.
pub fn finish(p: Parser) -> result[bool, str] {
    if p.state != S_DONE { return err("multipart: body ended before the closing boundary"); }
    return ok(true);
}

// A whole part with its data, from parse.
pub struct Item {
    part: Part,
    data: bytes,
}

// Every part of a body already in memory.
pub fn parse(body: bytes, boundary: str) -> result[[Item], str] {
    let p = parser(boundary);
    let er = feed(p, body);
    guard let evs = er else let e = err_of(er) { return err(e); }
    let fr = finish(p);
    guard let _f = fr else let fe = err_of(fr) { return err(fe); }
    let items: [Item] = [];
    let cur = builder.new_bytes();
    let part = empty_part();
    for e in evs {
        if e.kind == PART { part = e.part; cur = builder.new_bytes(); }
        else if e.kind == DATA { cur.write(e.data); }
        else if e.kind == PART_END { push(items, Item { part: part, data: cur.finish() }); }
    }
    return ok(items);
}

// ---- writing ---------------------------------------------------------------

pub gc struct Body {
    boundary: str,
    b: builder.Bytes,
}

// A body to fill with fields and files; boundary should be random and
// not occur in the data (a 32-character hex token from a CSPRNG does).
pub fn body(boundary: str) -> Body {
    return Body { boundary: boundary, b: builder.new_bytes() };
}

pub fn add_field(w: Body, name: str, value: str) {
    w.b.write_str("--" + w.boundary + "\r\n");
    w.b.write_str("Content-Disposition: form-data; name=\"" + quote(name) + "\"\r\n\r\n");
    w.b.write_str(value);
    w.b.write_str("\r\n");
}

pub fn add_file(w: Body, name: str, filename: str, content_type: str, data: bytes) {
    let ct = content_type;
    if len(ct) == 0 { ct = "application/octet-stream"; }
    w.b.write_str("--" + w.boundary + "\r\n");
    w.b.write_str("Content-Disposition: form-data; name=\"" + quote(name) +
                  "\"; filename=\"" + quote(filename) + "\"\r\n");
    w.b.write_str("Content-Type: " + strip_crlf(ct) + "\r\n\r\n");
    w.b.write(data);
    w.b.write_str("\r\n");
}

// The finished body and the Content-Type to send it with.
pub fn close(w: Body) -> bytes {
    w.b.write_str("--" + w.boundary + "--\r\n");
    return w.b.finish();
}

pub fn content_type(w: Body) -> str {
    return "multipart/form-data; boundary=" + w.boundary;
}

// ---- internals -------------------------------------------------------------

fn ev(kind: int, data: bytes) -> Event {
    return Event { kind: kind, part: empty_part(), data: data };
}

fn empty_part() -> Part {
    let h: map[str]str = {};
    return Part { name: "", filename: "", content_type: "text/plain", headers: h };
}

// The first occurrence of needle in hay at or after from, or -1.
fn find(hay: bytes, needle: bytes, from: int) -> int {
    let n = len(needle);
    if n == 0 { return from; }
    let first = needle[0] as int;
    let i = from;
    while i + n <= len(hay) {
        let j = byteutil.find(hay, i, first);
        if j < 0 || j + n > len(hay) { return -1; }
        if hay[j..j + n] == needle { return j; }
        i = j + 1;
    }
    return -1;
}

fn parse_part_head(head: str) -> result[Part, str] {
    let part = empty_part();
    for line in strings.split(head, "\r\n") {
        if len(line) == 0 { continue; }
        let c = strings.find(line, ":");
        if c <= 0 { return err("multipart: malformed part header"); }
        let name = strings.to_lower(strings.trim(strings.slice(line, 0, c)));
        let value = strings.trim(strings.slice(line, c + 1, len(line)));
        part.headers[name] = value;
        if name == "content-type" { part.content_type = value; }
        if name == "content-disposition" {
            part.name = param(value, "name");
            let star = param(value, "filename*");
            if len(star) > 0 { part.filename = rfc5987(star); }
            else { part.filename = param(value, "filename"); }
        }
    }
    return ok(part);
}

// A parameter of a header value: name="quoted \" value" or name=token.
fn param(v: str, key: str) -> str {
    let b = to_bytes(v);
    let i = 0;
    while i < len(b) {
        // find "; key=" at a parameter start
        let semi = byteutil.find(b, i, 59);
        if semi < 0 { return ""; }
        let j = semi + 1;
        while j < len(b) && (b[j] as int) == 32 { j = j + 1; }
        let k = to_bytes(key + "=");
        if j + len(k) <= len(b) && strings.to_lower(to_str(b[j..j + len(k)])) == key + "=" {
            let at = j + len(k);
            if at < len(b) && (b[at] as int) == 34 {
                let out = builder.new_bytes();
                let p = at + 1;
                while p < len(b) && (b[p] as int) != 34 {
                    if (b[p] as int) == 92 && p + 1 < len(b) { p = p + 1; }
                    out.write_byte(b[p] as int);
                    p = p + 1;
                }
                return to_str(out.finish());
            }
            let end = at;
            while end < len(b) && (b[end] as int) != 59 { end = end + 1; }
            return strings.trim(to_str(b[at..end]));
        }
        i = semi + 1;
    }
    return "";
}

// filename*=UTF-8''na%C3%AFve.txt
fn rfc5987(v: str) -> str {
    let q = strings.find(v, "''");
    if q < 0 { return v; }
    let enc = strings.slice(v, q + 2, len(v));
    let b = to_bytes(enc);
    let out = builder.new_bytes();
    let i = 0;
    while i < len(b) {
        let c = b[i] as int;
        if c == 37 && i + 2 < len(b) {
            let h = hexv(b[i + 1] as int) * 16 + hexv(b[i + 2] as int);
            if h >= 0 { out.write_byte(h); i = i + 3; continue; }
        }
        out.write_byte(c);
        i = i + 1;
    }
    return to_str(out.finish());
}

fn hexv(c: int) -> int {
    if c >= 48 && c <= 57 { return c - 48; }
    if c >= 97 && c <= 102 { return c - 87; }
    if c >= 65 && c <= 70 { return c - 55; }
    return -1000;
}

fn quote(s: str) -> str {
    return strings.replace(strings.replace(strip_crlf(s), "\\", "\\\\"), "\"", "\\\"");
}

fn strip_crlf(s: str) -> str {
    return strings.replace(strings.replace(s, "\r", ""), "\n", "");
}
