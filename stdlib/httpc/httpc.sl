import "net";
import "time";
import "strings";
import "compress";

// HTTP/1.1 client.
//
// The mirror of `http`: that package parses a REQUEST and serialises a
// RESPONSE, which is what a server does. This one serialises a request
// and parses a response. They are separate packages rather than one
// because `http` imports only `byteutil`, while a client necessarily
// imports `net` -- and for a TLS request that drags -lssl/-lcrypto onto
// the link line of every program that merely wanted to serve HTTP.
//
// The connection is addressed by a Transport -- an fd for http, an SSL
// handle for https -- and not by a `link`, for the same reason
// http2/conn.sl gives: `link` is move-only, and a redirect chain has to
// hand the connection through several frames.
//
// Two ways in. httpc.get / post / head / send are one-shot: a fresh
// connection per request, closed afterwards. A Client (new_client) keeps
// idle connections and reuses them. They are ONE code path -- the
// one-shot functions are a client that keeps nothing -- so framing,
// redirects, decompression and every security rule below cannot drift
// between the two.
//
// WHAT THIS DOES NOT DO, deliberately: no HTTP/2, no multipart bodies,
// no proxy support.

// ---- limits ----------------------------------------------------------
//
// A client talks to servers it does not control, so every buffer it
// fills on their say-so needs a ceiling. Without these a hostile (or
// merely broken) server can make a slang program allocate until the OS
// kills it, which is a denial of service that arrives through an
// ordinary API call.

let MAX_HEAD = 65536;         // status line + all headers
let MAX_BODY = 33554432;      // 32 MiB
let MAX_CHUNK_LINE = 64;      // a chunk size line, generously
let READ_CHUNK = 65536;

pub gc struct Url {
    scheme: str,      // "http" or "https"
    host: str,        // no brackets, even for IPv6
    port: int,
    path: str,        // path + query, ready to put in the request line
}

pub gc struct Request {
    method: str,
    url: str,
    headers: map[str]str,
    body: bytes,
    // 0 disables following entirely. The default from new_request is 5,
    // which is what curl and every browser use.
    max_redirects: int,
    // A PEM bundle to verify the server against, or "" for the system
    // trust store. Present because the usual reason a server program
    // makes an outbound HTTPS call is to reach another service inside
    // the same organisation, and those are routinely signed by a
    // private CA the system store has never heard of. Verification is
    // NOT optional either way -- there is no field that turns it off.
    ca_path: str,
}

pub gc struct Response {
    status: int,
    status_text: str,
    headers: map[str]str,
    body: bytes,
    // The URL this body actually came from. After a redirect chain that
    // is NOT the URL the caller asked for, and a caller resolving
    // relative links in the body needs the one that answered.
    url: str,
}

// ---- URL parsing -----------------------------------------------------

fn is_digit(b: int) -> bool {
    return b >= 48 && b <= 57;
}

// The authority ends at the first '/', '?' or '#'. Returns len(s) when
// the URL is bare ("http://example.com").
fn authority_end(s: str) -> int {
    let b = to_bytes(s);
    let i = 0;
    while i < len(b) {
        if b[i] == 47 || b[i] == 63 || b[i] == 35 {
            return i;
        }
        i = i + 1;
    }
    return len(b);
}

pub fn parse_url(u: str) -> result[Url, str] {
    let low = strings.to_lower(u);
    let scheme = "";
    let after = 0;
    if strings.has_prefix(low, "http://") {
        scheme = "http";
        after = 7;
    } else if strings.has_prefix(low, "https://") {
        scheme = "https";
        after = 8;
    } else {
        return err("url must begin with http:// or https://: " + u);
    }

    let rest = strings.slice(u, after, len(u));
    let aend = authority_end(rest);
    let authority = strings.slice(rest, 0, aend);
    let path = strings.slice(rest, aend, len(rest));
    if path == "" {
        path = "/";
    }
    if authority == "" {
        return err("url has no host: " + u);
    }

    // Credentials in the authority are refused rather than dropped.
    // Dropping them silently sends an unauthenticated request that
    // comes back 401, and the cause is invisible at the call site.
    if strings.contains(authority, "@") {
        return err("credentials in the url are not supported; set an " +
                   "Authorization header instead (encoding.base64_encode " +
                   "builds a Basic one): " + u);
    }

    let host = authority;
    let port = 80;
    if scheme == "https" {
        port = 443;
    }

    // An IPv6 literal is bracketed precisely so its colons cannot be
    // read as a port separator, so it has to be unwrapped before the
    // port split rather than after.
    if strings.has_prefix(authority, "[") {
        let close = strings.find(authority, "]");
        if close < 0 {
            return err("unterminated IPv6 literal in url: " + u);
        }
        host = strings.slice(authority, 1, close);
        let tail = strings.slice(authority, close + 1, len(authority));
        if tail != "" {
            if !strings.has_prefix(tail, ":") {
                return err("junk after IPv6 literal in url: " + u);
            }
            let pr = to_int(strings.slice(tail, 1, len(tail)));
            guard let p = pr else let e = err_of(pr) {
                return err("bad port in url: " + e);
            }
            port = p;
        }
    } else {
        let colon = strings.rfind(authority, ":");
        if colon >= 0 {
            let pr = to_int(strings.slice(authority, colon + 1,
                                          len(authority)));
            guard let p = pr else let e = err_of(pr) {
                return err("bad port in url: " + e);
            }
            port = p;
            host = strings.slice(authority, 0, colon);
        }
    }

    if host == "" {
        return err("url has no host: " + u);
    }
    if port <= 0 || port > 65535 {
        return err("port out of range in url: " + u);
    }
    return ok(Url { scheme: scheme, host: host, port: port, path: path });
}

// The origin, for comparing two URLs across a redirect. Scheme and port
// are part of it: https->http on the same host is a downgrade, and
// credentials must not survive it.
fn origin_of(u: Url) -> str {
    return u.scheme + "://" + u.host + ":" + to_str(u.port);
}

// ---- transport -------------------------------------------------------

gc struct Transport {
    fd: i32,        // the socket; 0 and unused when ssl is set
    ssl: rawptr,    // nullptr for cleartext
}

fn tr_send(t: Transport, b: bytes, u: until) -> result[i32, str] {
    if t.ssl == nullptr {
        return net.send_until(t.fd, b, u);
    }
    return net.tls_send_until(t.ssl, b, u);
}

fn tr_recv(t: Transport, max: int, u: until) -> result[bytes, str] {
    if t.ssl == nullptr {
        return net.recv_until(t.fd, max, u);
    }
    return net.tls_recv_until(t.ssl, max, u);
}

fn tr_close(t: Transport) {
    if t.ssl == nullptr {
        net.close(t.fd);
        return;
    }
    net.tls_close(t.ssl);
}

fn connect(u: Url, ca_path: str, deadline: until) -> result[Transport, str] {
    if u.scheme == "http" {
        let dr = net.dial(u.host, u.port);
        guard let fd = dr else let e = err_of(dr) {
            return err("dial " + u.host + ": " + e);
        }
        return ok(Transport { fd: fd, ssl: nullptr });
    }
    // The argument is a CA bundle PATH, not a hostname: "" selects
    // OpenSSL's default verify paths. SNI and hostname verification are
    // net.tls_dial's job -- it calls SSL_set_tlsext_host_name and
    // SSL_set1_host with the host below -- so neither is set here.
    let cr = net.tls_client_ctx(ca_path);
    guard let ctx = cr else let e = err_of(cr) {
        return err("tls context: " + e);
    }
    let tr = net.tls_dial(u.host, u.port, ctx);
    guard let ssl = tr else let e = err_of(tr) {
        return err("tls dial " + u.host + ": " + e);
    }
    return ok(Transport { fd: 0, ssl: ssl });
}

// ---- request serialisation -------------------------------------------

fn host_header(u: Url) -> str {
    // The default port is omitted: RFC 9110 says the two forms are
    // equivalent, but virtual-host routing on real servers is done by
    // string match, and "example.com:443" misses.
    let host = u.host;
    if strings.contains(host, ":") {
        host = "[" + host + "]";    // IPv6 literal, re-bracketed
    }
    if u.scheme == "http" && u.port == 80 {
        return host;
    }
    if u.scheme == "https" && u.port == 443 {
        return host;
    }
    return host + ":" + to_str(u.port);
}

// Header names a caller may not set, because this function owns them
// and a duplicate would either be ignored or -- for Content-Length --
// be a request-smuggling vector.
fn is_reserved(name: str) -> bool {
    return name == "host" || name == "content-length" ||
           name == "connection" || name == "transfer-encoding";
}

fn serialize(method: str, u: Url, headers: map[str]str,
             body: bytes, keep_alive: bool) -> bytes {
    let head = method + " " + u.path + " HTTP/1.1\r\n";
    head = head + "Host: " + host_header(u) + "\r\n";
    // A client that will not keep the connection says so. The server
    // can then close as soon as it has answered instead of holding an
    // idle socket open for a reuse that is never coming. Keep-alive is
    // HTTP/1.1's default, so the pooled case sends nothing.
    if !keep_alive {
        head = head + "Connection: close\r\n";
    }
    head = head + "Content-Length: " + to_str(len(body)) + "\r\n";

    for k, v in headers {
        if !is_reserved(strings.to_lower(k)) {
            head = head + k + ": " + v + "\r\n";
        }
    }
    head = head + "\r\n";
    return to_bytes(head) + body;
}

// ---- response parsing ------------------------------------------------

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

fn find_head_end(b: bytes, from: int) -> int {
    let i = from;
    while i + 3 < len(b) {
        if b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10 {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

fn trim_ows(s: str) -> str {
    return strings.trim(s);
}

// "HTTP/1.1 200 OK". The reason phrase is optional (RFC 9112 allows it
// to be empty) and is not required to be anything in particular, so
// only the version and the three-digit code are validated.
fn parse_status(line: str) -> result[Response, str] {
    if !strings.has_prefix(line, "HTTP/1.") {
        return err("not an HTTP/1.x response: " + line);
    }
    let sp = strings.find(line, " ");
    if sp < 0 {
        return err("malformed status line: " + line);
    }
    let rest = strings.slice(line, sp + 1, len(line));
    let sp2 = strings.find(rest, " ");
    let code_s = rest;
    let reason = "";
    if sp2 >= 0 {
        code_s = strings.slice(rest, 0, sp2);
        reason = strings.slice(rest, sp2 + 1, len(rest));
    }
    if len(code_s) != 3 {
        return err("malformed status code: " + line);
    }
    let cr = to_int(code_s);
    guard let code = cr else {
        return err("malformed status code: " + line);
    }
    let h: map[str]str = {};
    return ok(Response { status: code, status_text: reason, headers: h,
                         body: b"", url: "" });
}

fn parse_headers(raw: bytes, start: int, stop: int)
        -> result[map[str]str, str] {
    let headers: map[str]str = {};
    let i = start;
    while i < stop {
        let eol = find_crlf(raw, i);
        if eol < 0 || eol > stop {
            return err("malformed header");
        }
        if eol == i {
            break;
        }
        // A leading space means an obs-fold continuation. RFC 9112
        // removed it, and accepting it is a smuggling vector, so it is
        // refused rather than joined.
        if raw[i] == 32 || raw[i] == 9 {
            return err("obsolete line folding in a header");
        }
        let line = to_str(raw[i..eol]);
        let colon = strings.find(line, ":");
        if colon <= 0 {
            return err("malformed header: " + line);
        }
        let name = strings.to_lower(strings.slice(line, 0, colon));
        let value = trim_ows(strings.slice(line, colon + 1, len(line)));
        // Repeats are joined with ", " per RFC 9110 section 5.3 rather
        // than overwritten: two Set-Cookie lines are two cookies, and
        // keeping only the last one loses data silently.
        if has(headers, name) {
            headers[name] = headers[name] + ", " + value;
        } else {
            headers[name] = value;
        }
        i = eol + 2;
    }
    return ok(headers);
}

pub fn header(r: Response, name: str) -> opt[str] {
    let k = strings.to_lower(name);
    if has(r.headers, k) {
        return some(r.headers[k]);
    }
    return none;
}

// ---- body reading ----------------------------------------------------

fn hex_val(b: int) -> int {
    if b >= 48 && b <= 57 { return b - 48; }
    if b >= 97 && b <= 102 { return b - 97 + 10; }
    if b >= 65 && b <= 70 { return b - 65 + 10; }
    return -1;
}

// A chunk size line is hex, optionally followed by ';' and extensions
// this client ignores. Returns -1 for anything else.
fn parse_chunk_size(s: str) -> int {
    let b = to_bytes(s);
    let i = 0;
    let n = 0;
    let any = false;
    while i < len(b) {
        if b[i] == 59 {     // ';' -- extensions start, stop here
            break;
        }
        let v = hex_val(b[i]);
        if v < 0 {
            return -1;
        }
        // Refuse rather than wrap. A size this large is a hostile
        // server, and the cap below would reject it anyway.
        if n > 268435456 {
            return -1;
        }
        n = n * 16 + v;
        any = true;
        i = i + 1;
    }
    if !any {
        return -1;
    }
    return n;
}

gc struct Reader {
    t: Transport,
    buf: bytes,       // bytes received and not yet consumed
    eof: bool,
    // Whether ANY byte of a response arrived. A pooled connection that
    // fails before the first byte most likely died while idle, which is
    // the one case where retrying on a fresh connection is sound.
    got_any: bool,
    http11: bool,
}

// Pull until the reader holds at least `want` bytes, or the peer closes.
fn fill_to(r: Reader, want: int, deadline: until) -> result[bool, str] {
    while len(r.buf) < want {
        if r.eof {
            return ok(false);
        }
        let rr = tr_recv(r.t, READ_CHUNK, deadline);
        guard let got = rr else let e = err_of(rr) {
            return err("recv: " + e);
        }
        if len(got) == 0 {
            r.eof = true;
            return ok(false);
        }
        r.got_any = true;
        r.buf = r.buf + got;
        if len(r.buf) > MAX_BODY {
            return err("response body exceeds the 32 MiB limit");
        }
    }
    return ok(true);
}

fn read_chunked(r: Reader, deadline: until) -> result[bytes, str] {
    let out = b"";
    while true {
        // the size line
        let eol = find_crlf(r.buf, 0);
        while eol < 0 {
            if len(r.buf) > MAX_CHUNK_LINE {
                return err("chunk size line too long");
            }
            let fr = fill_to(r, len(r.buf) + 1, deadline);
            guard let more = fr else let e = err_of(fr) {
                return err(e);
            }
            if !more {
                return err("connection closed inside a chunk header");
            }
            eol = find_crlf(r.buf, 0);
        }
        let size = parse_chunk_size(to_str(r.buf[0..eol]));
        if size < 0 {
            return err("malformed chunk size");
        }
        r.buf = r.buf[eol + 2..];

        if size == 0 {
            // Trailers, then a blank line. They are read and discarded:
            // keeping them would mean merging a second header block
            // into one already handed to the caller.
            while true {
                let te = find_crlf(r.buf, 0);
                while te < 0 {
                    let fr2 = fill_to(r, len(r.buf) + 1, deadline);
                    guard let more2 = fr2 else let e = err_of(fr2) {
                        return err(e);
                    }
                    if !more2 {
                        return ok(out);   // server closed after the 0 chunk
                    }
                    te = find_crlf(r.buf, 0);
                }
                let done = te == 0;
                r.buf = r.buf[te + 2..];
                if done {
                    return ok(out);
                }
            }
        }

        if len(out) + size > MAX_BODY {
            return err("response body exceeds the 32 MiB limit");
        }
        let fr3 = fill_to(r, size + 2, deadline);
        guard let more3 = fr3 else let e = err_of(fr3) {
            return err(e);
        }
        if !more3 {
            return err("connection closed inside a chunk body");
        }
        out = out + r.buf[0..size];
        r.buf = r.buf[size + 2..];      // the chunk's trailing CRLF
    }
    return ok(out);
}

fn read_body(r: Reader, headers: map[str]str, status: int, method: str,
             deadline: until) -> result[bytes, str] {
    // Responses that carry no body however the headers read. A
    // Content-Length on any of these is advisory and must be ignored,
    // or the client hangs waiting for bytes that never come.
    if method == "HEAD" || status == 204 || status == 304 ||
       (status >= 100 && status < 200) {
        return ok(b"");
    }

    if has(headers, "transfer-encoding") {
        let te = strings.to_lower(headers["transfer-encoding"]);
        if strings.contains(te, "chunked") {
            return read_chunked(r, deadline);
        }
        return err("unsupported Transfer-Encoding: " + te);
    }

    if has(headers, "content-length") {
        let cr = to_int(trim_ows(headers["content-length"]));
        guard let n = cr else let e = err_of(cr) {
            return err("bad Content-Length: " + e);
        }
        if n < 0 {
            return err("negative Content-Length");
        }
        if n > MAX_BODY {
            return err("response body exceeds the 32 MiB limit");
        }
        let fr = fill_to(r, n, deadline);
        guard let more = fr else let e = err_of(fr) {
            return err(e);
        }
        if !more {
            return err("connection closed with " + to_str(n - len(r.buf)) +
                       " body bytes outstanding");
        }
        // Consume exactly n. Returning a slice and leaving the bytes in
        // the buffer was harmless when every connection closed after one
        // response; with pooling, anything left behind would be read as
        // the start of the NEXT response on this connection.
        let body = r.buf[0..n];
        r.buf = r.buf[n..];
        return ok(body);
    }

    // Neither framing header: the body runs to end of connection. That
    // leaves r.eof set, which is what keeps the connection out of the
    // pool -- a separate "close-delimited" flag was tried and removed,
    // because a control showed it could never change the outcome.
    while !r.eof {
        let fr = fill_to(r, len(r.buf) + 1, deadline);
        guard let _m = fr else let e = err_of(fr) {
            return err(e);
        }
    }
    return ok(r.buf);
}

fn read_response(r: Reader, method: str, deadline: until)
        -> result[Response, str] {
    let sep = find_head_end(r.buf, 0);
    while sep < 0 {
        if len(r.buf) > MAX_HEAD {
            return err("response headers exceed 64 KiB");
        }
        let fr = fill_to(r, len(r.buf) + 1, deadline);
        guard let more = fr else let e = err_of(fr) {
            return err(e);
        }
        if !more {
            if len(r.buf) == 0 {
                return err("connection closed before any response");
            }
            return err("connection closed inside the response headers");
        }
        sep = find_head_end(r.buf, 0);
    }

    let line_end = find_crlf(r.buf, 0);
    if line_end < 0 || line_end > sep {
        return err("malformed status line");
    }
    let status_line = to_str(r.buf[0..line_end]);
    r.http11 = strings.has_prefix(status_line, "HTTP/1.1 ");
    let sr = parse_status(status_line);
    guard let resp = sr else let e = err_of(sr) {
        return err(e);
    }
    let hr = parse_headers(r.buf, line_end + 2, sep);
    guard let headers = hr else let e = err_of(hr) {
        return err(e);
    }
    resp.headers = headers;
    r.buf = r.buf[sep + 4..];

    let br = read_body(r, headers, resp.status, method, deadline);
    guard let body = br else let e = err_of(br) {
        return err(e);
    }
    resp.body = body;
    return ok(resp);
}

// ---- redirects -------------------------------------------------------

fn is_redirect(status: int) -> bool {
    return status == 301 || status == 302 || status == 303 ||
           status == 307 || status == 308;
}

// Resolve a Location against the URL that produced it. Absolute and
// root-relative cover essentially every real redirect; a relative path
// without a leading '/' is legal per RFC 3986 and rare enough that
// guessing at it is worse than saying so.
fn resolve_location(base: Url, loc: str) -> result[str, str] {
    let low = strings.to_lower(loc);
    if strings.has_prefix(low, "http://") || strings.has_prefix(low, "https://") {
        return ok(loc);
    }
    if strings.has_prefix(loc, "/") {
        return ok(base.scheme + "://" + host_header(base) + loc);
    }
    return err("relative Location is not supported: " + loc);
}

// 303 always becomes GET. 301 and 302 do too when the original was a
// POST -- that is what every browser and curl do, and what servers
// therefore expect, whatever the RFC's original wording said. 307 and
// 308 exist precisely to preserve the method, so they do.
fn method_after(status: int, method: str) -> str {
    if status == 307 || status == 308 {
        return method;
    }
    if method == "HEAD" {
        return "HEAD";
    }
    return "GET";
}

// ---- content decoding ------------------------------------------------
//
// The client asks for gzip and deflate ONLY when the caller did not set
// Accept-Encoding, and decodes ONLY when it asked -- Go's rule, and the
// right one. A caller who set the header wants the bytes as the server
// sent them (to proxy them, to store them compressed), and silently
// decompressing would hand back something other than what they asked
// for.

fn caller_set(headers: map[str]str, lname: str) -> bool {
    for k, _v in headers {
        if strings.to_lower(k) == lname {
            return true;
        }
    }
    return false;
}

// Decoded size is held to the same ceiling as a plain body. Without it
// the 32 MiB limit on the wire would mean nothing: a 32 MiB gzip body
// can hold tens of gigabytes.
fn decode_body(resp: Response) -> result[bool, str] {
    if !has(resp.headers, "content-encoding") {
        return ok(true);
    }
    let ce = strings.to_lower(trim_ows(resp.headers["content-encoding"]));
    if len(resp.body) == 0 || ce == "identity" || ce == "" {
        del(resp.headers, "content-encoding");
        return ok(true);
    }
    if ce == "gzip" || ce == "x-gzip" {
        let gr = compress.gunzip(resp.body, MAX_BODY);
        guard let plain = gr else let e = err_of(gr) {
            return err("gzip response: " + e);
        }
        resp.body = plain;
    } else if ce == "deflate" {
        // RFC 9110 says "deflate" is the zlib container. A real share of
        // servers send raw DEFLATE under that name anyway, so the zlib
        // reading is tried first and raw is the fallback, rather than
        // failing a response the server clearly meant to be readable.
        let zr = compress.inflate(resp.body, MAX_BODY);
        guard let zplain = zr else {
            let rr = compress.inflate_raw(resp.body, MAX_BODY);
            guard let rplain = rr else let e = err_of(rr) {
                return err("deflate response: " + e);
            }
            resp.body = rplain;
            del(resp.headers, "content-encoding");
            del(resp.headers, "content-length");
            return ok(true);
        }
        resp.body = zplain;
    } else {
        // An encoding we did not ask for and cannot read. The header is
        // left in place, so this is visible rather than silent: the
        // caller sees exactly what arrived and what it is encoded with.
        return ok(true);
    }
    // Both describe the bytes that crossed the wire, not the body now
    // in hand, so keeping them would be a lie about the Response.
    del(resp.headers, "content-encoding");
    del(resp.headers, "content-length");
    return ok(true);
}

// ---- the connection pool ---------------------------------------------

gc struct Idle {
    key: str,
    t: Transport,
    since: duration,  // time.mono() when it went idle
}

gc struct Lease {
    found: bool,
    t: Transport,
}

// Bounds the pool across ALL hosts, so a client that talks to many
// origins cannot accumulate file descriptors without limit.
let MAX_IDLE_TOTAL = 64;

pub gc struct Client {
    // Idle connections kept per origin. 0 keeps none, which is exactly
    // what the one-shot httpc.get and friends are.
    max_idle_per_host: int,
    // Nanoseconds an idle connection may wait before it is closed rather
    // than reused.
    idle_timeout: int,
    idle: [Idle],
    lock: mutex,
    // How many connections were opened, and how many requests rode an
    // existing one. Kept because "the pool works" is otherwise a claim
    // nothing can check.
    dials: int,
    reuses: int,
}

pub fn new_client() -> Client {
    let none_idle: [Idle] = [];
    return Client { max_idle_per_host: 4, idle_timeout: 30000000000,
                    idle: none_idle, lock: make_mutex(), dials: 0,
                    reuses: 0 };
}

fn tr_alive(t: Transport) -> bool {
    if t.ssl == nullptr {
        return net.idle_alive(t.fd);
    }
    return net.tls_idle_alive(t.ssl);
}

// Newest first: the most recently used connection is the one least
// likely to have been closed by the server's own idle timer.
//
// Every connection taken from the pool is PROBED before use. Servers
// close idle connections on timers of their own -- Node's default is 5
// seconds -- and a request written onto a connection the server already
// closed fails in a way that cannot be told apart from the server
// failing mid-request. The probe is one non-blocking MSG_PEEK: no
// latency, nothing consumed.
fn take_idle(c: Client, key: str) -> Lease {
    let found = false;
    let got = Transport { fd: 0, ssl: nullptr };
    let now = time.mono();
    let keep: [Idle] = [];
    mutex_lock(c.lock);
    let i = len(c.idle) - 1;
    while i >= 0 {
        let it = c.idle[i];
        let expired = now - it.since > c.idle_timeout;
        if expired {
            tr_close(it.t);
        } else if !found && it.key == key {
            if tr_alive(it.t) {
                found = true;
                got = it.t;
            } else {
                tr_close(it.t);     // closed or chatty while idle
            }
        } else {
            keep = [it] + keep;
        }
        i = i - 1;
    }
    c.idle = keep;
    if found {
        c.reuses = c.reuses + 1;
    }
    mutex_unlock(c.lock);
    return Lease { found: found, t: got };
}

fn put_idle(c: Client, key: str, t: Transport) {
    mutex_lock(c.lock);
    let same = 0;
    for it in c.idle {
        if it.key == key {
            same = same + 1;
        }
    }
    if same >= c.max_idle_per_host {
        mutex_unlock(c.lock);
        tr_close(t);
        return;
    }
    c.idle = c.idle + [Idle { key: key, t: t, since: time.mono() }];
    if len(c.idle) > MAX_IDLE_TOTAL {
        tr_close(c.idle[0].t);      // oldest overall
        c.idle = c.idle[1..];
    }
    mutex_unlock(c.lock);
}

fn count_dial(c: Client) {
    mutex_lock(c.lock);
    c.dials = c.dials + 1;
    mutex_unlock(c.lock);
}

// Retrying is sound only when the request may be repeated. A POST that
// died on a stale connection might have reached the server before the
// connection did, and sending it twice could charge a card twice. The
// probe in take_idle is what protects a POST; this is the backstop for
// the narrow race where the server closes between the probe and the
// write.
fn idempotent(method: str) -> bool {
    return method == "GET" || method == "HEAD" || method == "OPTIONS" ||
           method == "TRACE" || method == "PUT" || method == "DELETE";
}

fn conn_close_requested(headers: map[str]str) -> bool {
    if !has(headers, "connection") {
        return false;
    }
    return strings.contains(strings.to_lower(headers["connection"]), "close");
}

fn exchange(c: Client, method: str, u: Url, headers: map[str]str,
            body: bytes, ca_path: str, deadline: until)
        -> result[Response, str] {
    // The key includes the CA bundle: a connection verified against one
    // trust anchor must never be handed to a request that asked for
    // another.
    let key = origin_of(u) + "|" + ca_path;
    let pooled = c.max_idle_per_host > 0;
    let force_fresh = false;

    while true {
        let reused = false;
        let t = Transport { fd: 0, ssl: nullptr };
        if pooled && !force_fresh {
            let lease = take_idle(c, key);
            if lease.found {
                reused = true;
                t = lease.t;
            }
        }
        if !reused {
            let cr = connect(u, ca_path, deadline);
            guard let fresh = cr else let e = err_of(cr) {
                return err(e);
            }
            t = fresh;
            count_dial(c);
        }

        let can_retry = reused && idempotent(method);

        let raw = serialize(method, u, headers, body, pooled);
        let sr = tr_send(t, raw, deadline);
        guard let _n = sr else let e = err_of(sr) {
            tr_close(t);
            if can_retry && !until_hit(deadline) {
                force_fresh = true;
                continue;
            }
            return err("send: " + e);
        }

        let r = Reader { t: t, buf: b"", eof: false, got_any: false,
                         http11: false };
        let rr = read_response(r, method, deadline);
        guard let resp = rr else let e = err_of(rr) {
            tr_close(t);
            if can_retry && !r.got_any && !until_hit(deadline) {
                force_fresh = true;
                continue;
            }
            return err(e);
        }

        let reusable = pooled && r.http11 && !r.eof && len(r.buf) == 0 &&
                       !conn_close_requested(resp.headers);
        if reusable {
            put_idle(c, key, t);
        } else {
            tr_close(t);
        }
        return ok(resp);
    }
    return err("unreachable");
}

// ---- the request ------------------------------------------------------

pub fn new_request(method: str, url: str) -> Request {
    let h: map[str]str = {};
    return Request { method: method, url: url, headers: h, body: b"",
                     max_redirects: 5, ca_path: "" };
}

fn run(c: Client, req: Request, deadline: until) -> result[Response, str] {
    let url = req.url;
    let method = req.method;
    let body = req.body;
    let left = req.max_redirects;
    let ca_path = req.ca_path;

    // A private copy: adding Accept-Encoding, or stripping credentials on
    // a redirect, must not reach back into the caller's Request.
    let headers: map[str]str = {};
    for k, v in req.headers {
        headers[k] = v;
    }
    let we_decode = !caller_set(headers, "accept-encoding");
    if we_decode {
        headers["Accept-Encoding"] = "gzip, deflate";
    }

    while true {
        let ur = parse_url(url);
        guard let u = ur else let e = err_of(ur) {
            return err(e);
        }

        let rr = exchange(c, method, u, headers, body, ca_path, deadline);
        guard let resp = rr else let e = err_of(rr) {
            return err(e);
        }
        resp.url = url;

        if !is_redirect(resp.status) || left <= 0 ||
           !has(resp.headers, "location") {
            // A 3xx with nowhere to go is the server's answer, not an
            // error of ours -- hand it back rather than inventing one.
            if we_decode {
                let dr = decode_body(resp);
                guard let _d = dr else let e = err_of(dr) {
                    return err(e);
                }
            }
            return ok(resp);
        }

        let lr = resolve_location(u, resp.headers["location"]);
        guard let next = lr else let e = err_of(lr) {
            return err(e);
        }
        let nr = parse_url(next);
        guard let nu = nr else let e = err_of(nr) {
            return err("redirect: " + e);
        }

        // Credentials must not cross an origin. A redirect to another
        // host is exactly how a token gets exfiltrated, and the server
        // that sent the Location chose where it points.
        if origin_of(nu) != origin_of(u) {
            let clean: map[str]str = {};
            for k, v in headers {
                let lk = strings.to_lower(k);
                if lk != "authorization" && lk != "cookie" &&
                   lk != "proxy-authorization" {
                    clean[k] = v;
                }
            }
            headers = clean;
        }

        let nm = method_after(resp.status, method);
        if nm != method {
            body = b"";
        }
        method = nm;
        url = next;
        left = left - 1;
    }
    return err("unreachable");
}

// Client operations are handle-first package functions -- the idiom
// every stdlib package already uses (sql.exec(db, ...), net.tls_send(ssl,
// ...)) -- rather than methods. Methods were tried first and hit a
// language limit: a method cannot share a name with a package function,
// so `impl Client { fn get }` collides with httpc.get.

pub fn client_send(c: Client, req: Request, deadline: until)
        -> result[Response, str] {
    return run(c, req, deadline);
}

pub fn client_get(c: Client, url: str, deadline: until)
        -> result[Response, str] {
    return run(c, new_request("GET", url), deadline);
}

pub fn client_head(c: Client, url: str, deadline: until)
        -> result[Response, str] {
    return run(c, new_request("HEAD", url), deadline);
}

pub fn client_post(c: Client, url: str, content_type: str, body: bytes,
                   deadline: until) -> result[Response, str] {
    let r = new_request("POST", url);
    r.headers["Content-Type"] = content_type;
    r.body = body;
    return run(c, r, deadline);
}

// How many connections are idle in the pool right now. With dials and
// reuses, the third number that makes the pool's behaviour checkable
// rather than asserted -- and the only one that shows a reuse DECISION
// before the server's own close can mask it.
pub fn idle_count(c: Client) -> int {
    mutex_lock(c.lock);
    let n = len(c.idle);
    mutex_unlock(c.lock);
    return n;
}

// Close every idle connection now. A long-lived service does not need
// this -- idle_timeout reaps them -- but a program about to exit, or a
// test counting connections, does.
pub fn close_idle(c: Client) {
    mutex_lock(c.lock);
    for it in c.idle {
        tr_close(it.t);
    }
    let none_idle: [Idle] = [];
    c.idle = none_idle;
    mutex_unlock(c.lock);
}

// ---- one-shot -----------------------------------------------------------

// A client that keeps nothing: every request dials, sends
// Connection: close, and closes. Correct for a program making a handful
// of calls; a service making many to the same origin wants new_client.
fn oneshot() -> Client {
    let c = new_client();
    c.max_idle_per_host = 0;
    return c;
}

pub fn send(req: Request, deadline: until) -> result[Response, str] {
    return run(oneshot(), req, deadline);
}

pub fn get(url: str, deadline: until) -> result[Response, str] {
    return run(oneshot(), new_request("GET", url), deadline);
}

pub fn head(url: str, deadline: until) -> result[Response, str] {
    return run(oneshot(), new_request("HEAD", url), deadline);
}

pub fn post(url: str, content_type: str, body: bytes,
            deadline: until) -> result[Response, str] {
    let r = new_request("POST", url);
    r.headers["Content-Type"] = content_type;
    r.body = body;
    return run(oneshot(), r, deadline);
}
