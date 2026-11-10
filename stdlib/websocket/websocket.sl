// A WebSocket client (RFC 6455), over ws:// or wss://, with the
// permessage-deflate extension (RFC 7692) when asked for.
//
//     import "websocket";
//
//     let r = websocket.dial("wss://example.com/live", deadline);
//     guard let ws = r else let e = err_of(r) { panic(e); }
//     websocket.send_text(ws, "{\"subscribe\":\"prices\"}", deadline);
//     while true {
//         let mr = websocket.recv(ws, deadline);          // result[opt[Message], str]
//         guard let got = mr else let e = err_of(mr) { break; }
//         guard let m = got else { continue; }            // the deadline passed
//         if m.kind == websocket.Kind.Close { break; }
//         handle(websocket.text(m));
//     }
//     websocket.close(ws, 1000, "bye", deadline);
//
// Pings from the server are answered as they arrive; options().ping_every
// sends pings of its own and drops a connection whose server stops
// answering. Messages are reassembled from their fragments, text is
// checked to be UTF-8, and every size the server controls is bounded.
//
// One task reads (recv) at a time; any number may send. A send is one
// frame, written whole under a lock, so frames from different tasks never
// interleave.

import "builder";
import "compress";
import "crypto";
import "encoding";
import "httpc";
import "net";
import "strings";
import "time";
import "unicode";

let OP_CONT = 0;
let OP_TEXT = 1;
let OP_BINARY = 2;
let OP_CLOSE = 8;
let OP_PING = 9;
let OP_PONG = 10;

let ST_OPEN = 0;
let ST_CLOSING = 1;   // our close frame is sent; waiting for the server's
let ST_CLOSED = 2;

let MAX_HEAD = 16384;
let READ_CHUNK = 65536;
let MASK_POOL = 4096;

// What a received message is.
pub enum Kind {
    Text,
    Binary,
    // The server closed the connection: code and reason say why. The
    // close handshake is already answered; the connection is finished.
    Close,
}

pub gc struct Message {
    kind: Kind,
    data: bytes,
    // Close only: the status code (1005 when the server sent none) and
    // the reason text
    code: int,
    reason: str,
}

pub gc struct Options {
    // extra request headers, "Name: value" each (Authorization, cookies)
    headers: [str],
    // subprotocols to offer, in order of preference; the one the server
    // chose is Conn.protocol
    protocols: [str],
    // the Origin header, for servers that check it; "" sends none
    origin: str,
    // a CA bundle for wss://, "" for the system's
    ca_path: str,
    // the largest message accepted, after reassembly and decompression
    max_message: int,
    // offer permessage-deflate (RFC 7692)
    compress: bool,
    // send a ping this often (nanoseconds; 0 never), and drop the
    // connection when a ping goes a whole interval unanswered
    ping_every: int,
}

// The defaults: no extra headers or subprotocols, 32 MiB messages, no
// compression, no keepalive pings.
pub fn options() -> Options {
    return Options { headers: [], protocols: [], origin: "", ca_path: "", max_message: 33554432,
                     compress: false, ping_every: 0 };
}

pub gc struct Conn {
    // the subprotocol the server chose, or ""
    protocol: str,
    // the server's Sec-WebSocket-Extensions, as sent
    extensions: str,
    url: str,
    opts: Options,
    fd: int,
    ssl: rawptr,
    // permessage-deflate is on
    deflate: bool,
    // writes: one frame at a time; also guards the mask pool
    wlock: mutex,
    mask: bytes,
    mask_at: int,
    // state, the reader flag and keepalive bookkeeping
    slock: mutex,
    state: int,
    why: str,
    reading: bool,
    pings_unanswered: int,
    // bytes read but not yet parsed: data[pos..]
    data: bytes,
    pos: int,
    // a fragmented message in progress
    frag_op: int,
    frag_deflated: bool,
    frag_parts: [bytes],
    frag_size: int,
    // a text message's last fragment's incomplete UTF-8 character, to
    // check with the next (fragments are checked as they arrive)
    frag_carry: bytes,
}

// Connect to url (ws:// or wss://) with the default options.
pub fn dial(url: str, deadline: until) -> result[Conn, str] {
    return dial_with(url, options(), deadline);
}

// Connect, send the opening handshake, and check the server's answer.
pub fn dial_with(url: str, o: Options, deadline: until) -> result[Conn, str] {
    if o.max_message < 1 {
        return err("websocket: max_message must be positive");
    }
    if o.ping_every < 0 {
        return err("websocket: ping_every must not be negative");
    }
    let low = strings.to_lower(url);
    let as_http = "";
    if strings.has_prefix(low, "ws://") {
        as_http = "http://" + strings.slice(url, 5, len(url));
    } else if strings.has_prefix(low, "wss://") {
        as_http = "https://" + strings.slice(url, 6, len(url));
    } else {
        return err("websocket: url must begin with ws:// or wss://: " + url);
    }
    if strings.contains(url, "#") {
        // RFC 6455 section 3: a fragment has no meaning in a WebSocket URI
        return err("websocket: url must not have a #fragment: " + url);
    }
    let ur = httpc.parse_url(as_http);
    guard let u = ur else let e = err_of(ur) { return err("websocket: " + strings.replace(e, "http", "ws")); }
    for p in o.protocols {
        if !is_token(p) {
            return err("websocket: bad subprotocol name " + p);
        }
    }
    for h in o.headers {
        let colon = strings.find(h, ":");
        if colon <= 0 || strings.contains(h, "\r") || strings.contains(h, "\n") {
            return err("websocket: bad header line " + h);
        }
    }

    let c = Conn { protocol: "", extensions: "", url: url, opts: o, fd: -1, ssl: nullptr, deflate: false,
                   wlock: make_mutex(), mask: strings.bytes_zero(0), mask_at: 0, slock: make_mutex(),
                   state: ST_OPEN, why: "", reading: false, pings_unanswered: 0,
                   data: strings.bytes_zero(0), pos: 0, frag_op: -1, frag_deflated: false,
                   frag_parts: [], frag_size: 0, frag_carry: strings.bytes_zero(0) };
    if u.scheme == "http" {
        let dr = net.dial_until(u.host, u.port, deadline);
        guard let fd = dr else let e = err_of(dr) { return err("websocket: dial " + u.host + ": " + e); }
        c.fd = fd;
    } else {
        let cr = net.tls_client_ctx(o.ca_path);
        guard let ctx = cr else let e = err_of(cr) { return err("websocket: tls context: " + e); }
        let tr = net.tls_dial_until(u.host, u.port, ctx, deadline);
        guard let ssl = tr else let e = err_of(tr) { return err("websocket: tls dial " + u.host + ": " + e); }
        c.ssl = ssl;
    }
    let hr = handshake(c, u, deadline);
    guard let _h = hr else let e = err_of(hr) {
        close_transport(c);
        return err(e);
    }
    if o.ping_every > 0 {
        spawn pinger(c);
    }
    return ok(c);
}

fn is_token(s: str) -> bool {
    if s == "" {
        return false;
    }
    let b = to_bytes(s);
    for k in 0..len(b) {
        let ch = b[k];
        // RFC 7230 tchar
        let ok_ch = (ch >= 97 && ch <= 122) || (ch >= 65 && ch <= 90) || (ch >= 48 && ch <= 57) ||
                    ch == 33 || ch == 35 || ch == 36 || ch == 37 || ch == 38 || ch == 39 || ch == 42 ||
                    ch == 43 || ch == 45 || ch == 46 || ch == 94 || ch == 95 || ch == 96 || ch == 124 ||
                    ch == 126;
        if !ok_ch {
            return false;
        }
    }
    return true;
}

// ---- the opening handshake ------------------------------------------------------------

// The Sec-WebSocket-Accept a server must answer key with.
fn accept_for(key: str) -> str {
    return encoding.base64_encode(crypto.sha1(to_bytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
}

fn host_header(u: httpc.Url) -> str {
    let host = u.host;
    if strings.contains(host, ":") {
        host = "[" + host + "]";
    }
    if (u.scheme == "http" && u.port == 80) || (u.scheme == "https" && u.port == 443) {
        return host;
    }
    return host + ":" + to_str(u.port);
}

fn handshake(c: Conn, u: httpc.Url, deadline: until) -> result[bool, str] {
    let kr = crypto.rand(16);
    guard let nonce = kr else let e = err_of(kr) { return err("websocket: random key: " + e); }
    let key = encoding.base64_encode(nonce);
    let req = builder.new_str();
    req.write("GET ").write(u.path).write(" HTTP/1.1\r\n");
    req.write("Host: ").write(host_header(u)).write("\r\n");
    req.write("Upgrade: websocket\r\nConnection: Upgrade\r\n");
    req.write("Sec-WebSocket-Key: ").write(key).write("\r\n");
    req.write("Sec-WebSocket-Version: 13\r\n");
    if c.opts.origin != "" {
        req.write("Origin: ").write(c.opts.origin).write("\r\n");
    }
    if len(c.opts.protocols) > 0 {
        req.write("Sec-WebSocket-Protocol: ").write(strings.join(c.opts.protocols, ", ")).write("\r\n");
    }
    if c.opts.compress {
        // No context takeover either way: each message is compressed and
        // decompressed on its own, which is what compress's one-shot
        // deflate_raw/inflate_raw do, and it keeps no 32 KiB window per
        // direction per connection alive between messages.
        req.write("Sec-WebSocket-Extensions: permessage-deflate; client_no_context_takeover; " +
                  "server_no_context_takeover\r\n");
    }
    for h in c.opts.headers {
        req.write(h).write("\r\n");
    }
    req.write("\r\n");
    let wr = write_all(c, to_bytes(req.finish()), deadline);
    guard let _w = wr else let e = err_of(wr) { return err(e); }

    // the response head, up to the blank line
    let end = -1;
    while end < 0 {
        end = find_head_end(c.data);
        if end >= 0 {
            break;
        }
        if len(c.data) > MAX_HEAD {
            return err("websocket: handshake response head over 16 KiB");
        }
        let rr = read_more(c, deadline);
        guard let _r = rr else let e = err_of(rr) { return err("websocket: handshake: " + e); }
    }
    let head = strings.from_bytes(c.data, 0, end);
    c.pos = end + 4;
    let lines = strings.split(head, "\r\n");
    let status = lines[0];
    let parts = strings.split(status, " ");
    if len(parts) < 2 || !strings.has_prefix(parts[0], "HTTP/1.") {
        return err("websocket: not an HTTP response: " + shorten(status));
    }
    let hdrs: map[str]str = {};
    for k in 1..len(lines) {
        let colon = strings.find(lines[k], ":");
        if colon <= 0 {
            return err("websocket: bad header line in the response: " + shorten(lines[k]));
        }
        let name = strings.to_lower(strings.trim(strings.slice(lines[k], 0, colon)));
        let value = strings.trim(strings.slice(lines[k], colon + 1, len(lines[k])));
        if has(hdrs, name) {
            hdrs[name] = hdrs[name] + ", " + value;
        } else {
            hdrs[name] = value;
        }
    }
    if parts[1] != "101" {
        let msg = "websocket: the server answered " + strings.join(rest_of(parts, 1), " ") +
                  ", not 101 Switching Protocols";
        if has(hdrs, "location") {
            // a redirect is not followed: it would send the handshake,
            // and any credentials in it, somewhere the caller did not name
            msg = msg + " (redirect to " + hdrs["location"] + ")";
        }
        return err(msg);
    }
    if strings.to_lower(header_of(hdrs, "upgrade")) != "websocket" {
        return err("websocket: the response's Upgrade header is not websocket");
    }
    if !has_token(header_of(hdrs, "connection"), "upgrade") {
        return err("websocket: the response's Connection header has no upgrade");
    }
    if (header_of(hdrs, "sec-websocket-accept")) != accept_for(key) {
        return err("websocket: the response's Sec-WebSocket-Accept does not match the key");
    }
    let proto = header_of(hdrs, "sec-websocket-protocol");
    if proto != "" {
        let offered = false;
        for p in c.opts.protocols {
            if p == proto {
                offered = true;
            }
        }
        if !offered {
            return err("websocket: the server chose subprotocol " + proto + ", which was not offered");
        }
    }
    c.protocol = proto;
    let ext = header_of(hdrs, "sec-websocket-extensions");
    c.extensions = ext;
    if ext != "" {
        let er = accept_extensions(c, ext);
        guard let _e = er else let e = err_of(er) { return err(e); }
    }
    return ok(true);
}

fn header_of(h: map[str]str, name: str) -> str {
    if has(h, name) {
        return h[name];
    }
    return "";
}

fn rest_of(xs: [str], from: int) -> [str] {
    let out: [str] = [];
    for k in from..len(xs) {
        push(out, xs[k]);
    }
    return out;
}

fn find_head_end(b: bytes) -> int {
    let n = len(b);
    let i = 0;
    while i + 3 < n {
        if b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10 {
            return i;
        }
        i += 1;
    }
    return -1;
}

// A comma-separated header value contains this token (case-insensitive).
fn has_token(v: str, token: str) -> bool {
    for p in strings.split(v, ",") {
        if strings.to_lower(strings.trim(p)) == token {
            return true;
        }
    }
    return false;
}

// The server may answer only with what was offered: permessage-deflate,
// once, and only with parameters this client can honour.
fn accept_extensions(c: Conn, ext: str) -> result[bool, str] {
    if !c.opts.compress {
        return err("websocket: the server enabled extensions that were not offered: " + ext);
    }
    let exts = strings.split(ext, ",");
    if len(exts) != 1 {
        return err("websocket: the server enabled more than one extension: " + ext);
    }
    let params = strings.split(exts[0], ";");
    if strings.trim(params[0]) != "permessage-deflate" {
        return err("websocket: the server enabled an extension that was not offered: " + ext);
    }
    let server_nct = false;
    let seen: map[str]bool = {};
    for k in 1..len(params) {
        let p = strings.trim(params[k]);
        let name = p;
        let eq = strings.find(p, "=");
        let value = "";
        if eq >= 0 {
            name = strings.trim(strings.slice(p, 0, eq));
            value = strings.trim(strings.slice(p, eq + 1, len(p)));
        }
        if has(seen, name) {
            return err("websocket: permessage-deflate parameter " + name + " given twice");
        }
        seen[name] = true;
        if name == "server_no_context_takeover" && value == "" {
            server_nct = true;
        } else if name == "client_no_context_takeover" && value == "" {
            // this client never keeps context anyway
        } else if name == "server_max_window_bits" {
            // any window up to 15 bits inflates the same way
            let wr = to_int(strings.replace(value, "\"", ""));
            guard let w = wr else { return err("websocket: bad server_max_window_bits " + value); }
            if w < 8 || w > 15 {
                return err("websocket: bad server_max_window_bits " + value);
            }
        } else {
            // client_max_window_bits was not offered, so it may not come back
            return err("websocket: permessage-deflate parameter not offered: " + p);
        }
    }
    if !server_nct {
        return err("websocket: the server did not accept server_no_context_takeover");
    }
    c.deflate = true;
    return ok(true);
}

fn shorten(s: str) -> str {
    if len(s) > 120 {
        return strings.slice(s, 0, 120) + "...";
    }
    return s;
}

// ---- transport --------------------------------------------------------------------------

fn read_raw(c: Conn, n: int, deadline: until) -> result[bytes, str] {
    if c.ssl != nullptr {
        return net.tls_recv_until(c.ssl, n, deadline);
    }
    return net.recv_until(c.fd, n, deadline);
}

// Reads once more into the buffer.
fn read_more(c: Conn, deadline: until) -> result[bool, str] {
    let r = read_raw(c, READ_CHUNK, deadline);
    guard let b = r else let e = err_of(r) { return err(e); }
    if len(b) == 0 {
        return err("connection closed by the server");
    }
    if c.pos >= len(c.data) {
        c.data = b;
        c.pos = 0;
    } else {
        let parts: [bytes] = [c.data[c.pos..], b];
        c.data = strings.join_bytes(parts, b"");
        c.pos = 0;
    }
    return ok(true);
}

// Makes at least n unparsed bytes available. A large frame arrives in
// many reads: they are collected and joined once, not appended one by
// one (which copies everything read so far on every read). What was read
// stays buffered if the deadline passes, so the next call resumes.
fn fill(c: Conn, n: int, deadline: until) -> result[bool, str] {
    let have = len(c.data) - c.pos;
    if have >= n {
        return ok(true);
    }
    let parts: [bytes] = [];
    if have > 0 {
        push(parts, c.data[c.pos..]);
    }
    let failure = "";
    while have < n {
        let want = n - have;
        if want < READ_CHUNK {
            want = READ_CHUNK;
        }
        let r = read_raw(c, want, deadline);
        guard let b = r else let e = err_of(r) {
            failure = e;
            break;
        }
        if len(b) == 0 {
            failure = "connection closed by the server";
            break;
        }
        push(parts, b);
        have += len(b);
    }
    c.data = strings.join_bytes(parts, b"");
    c.pos = 0;
    if failure != "" {
        return err(failure);
    }
    return ok(true);
}

fn write_all(c: Conn, data: bytes, deadline: until) -> result[bool, str] {
    let off = 0;
    while off < len(data) {
        let chunk = data;
        if off > 0 {
            chunk = data[off..];
        }
        let r = send_raw(c, chunk, deadline);
        guard let n = r else let e = err_of(r) { return err("websocket: write: " + e); }
        if n <= 0 {
            return err("websocket: write: connection closed");
        }
        off += n as int;
    }
    return ok(true);
}

fn send_raw(c: Conn, b: bytes, deadline: until) -> result[i32, str] {
    if c.ssl != nullptr {
        return net.tls_send_until(c.ssl, b, deadline);
    }
    return net.send_until(c.fd, b, deadline);
}

fn close_transport(c: Conn) {
    if c.ssl != nullptr {
        net.tls_close(c.ssl);
        c.ssl = nullptr;
    }
    if c.fd >= 0 {
        net.close(c.fd);
        c.fd = -1;
    }
}

// ---- writing frames -----------------------------------------------------------------------

// Four unpredictable bytes for a frame's mask (RFC 6455 section 10.3
// requires a strong source), drawn from a pool refilled 4 KiB at a time
// so a frame does not cost a call into the OS's random source. The
// caller holds wlock.
fn next_mask(c: Conn) -> result[bytes, str] {
    if c.mask_at + 4 > len(c.mask) {
        let r = crypto.rand(MASK_POOL);
        guard let pool = r else let e = err_of(r) { return err("websocket: random mask: " + e); }
        c.mask = pool;
        c.mask_at = 0;
    }
    let k = c.mask[c.mask_at..c.mask_at + 4];
    c.mask_at += 4;
    return ok(k);
}

// The frame header for a payload of n bytes, mask key included.
fn frame_head(fin: bool, rsv1: bool, op: int, n: int, key: bytes) -> bytes {
    let hl = 2;
    if n > 65535 {
        hl = 10;
    } else if n > 125 {
        hl = 4;
    }
    let h = strings.bytes_zero(hl + 4);
    let b0 = op;
    if fin {
        b0 = b0 | 128;
    }
    if rsv1 {
        b0 = b0 | 64;
    }
    h[0] = b0;
    if hl == 2 {
        h[1] = 128 | n;
    } else if hl == 4 {
        h[1] = 128 | 126;
        h[2] = (n >> 8) & 255;
        h[3] = n & 255;
    } else {
        h[1] = 128 | 127;
        for k in 0..8 {
            h[2 + k] = (n >> (56 - 8 * k)) & 255;
        }
    }
    for k in 0..4 {
        h[hl + k] = key[k];
    }
    return h;
}

// One whole frame, masked, written under the lock.
fn write_frame(c: Conn, op: int, rsv1: bool, payload: bytes, deadline: until) -> result[bool, str] {
    mutex_lock(c.wlock);
    let mr = next_mask(c);
    guard let key = mr else let e = err_of(mr) {
        mutex_unlock(c.wlock);
        return err(e);
    }
    let frame = encoding.xor_mask(frame_head(true, rsv1, op, len(payload), key), payload, key);
    let r = write_all(c, frame, deadline);
    mutex_unlock(c.wlock);
    guard let _w = r else let e = err_of(r) {
        // a frame cut off part way leaves the stream unreadable
        fail_now(c, e);
        return err(e);
    }
    return ok(true);
}

fn check_open(c: Conn) -> result[bool, str] {
    mutex_lock(c.slock);
    let st = c.state;
    let why = c.why;
    mutex_unlock(c.slock);
    if st != ST_OPEN {
        if why == "" {
            return err("websocket: the connection is closing");
        }
        return err(why);
    }
    return ok(true);
}

fn send_data(c: Conn, op: int, payload: bytes, deadline: until) -> result[bool, str] {
    let cr = check_open(c);
    guard let _c = cr else let e = err_of(cr) { return err(e); }
    if c.deflate && len(payload) >= 64 {
        // compressed only when that is smaller: short or random payloads
        // grow under deflate
        let zr = compress.deflate_raw(payload);
        guard let z = zr else let e = err_of(zr) { return err("websocket: deflate: " + e); }
        if len(z) < len(payload) {
            return write_frame(c, op, true, z, deadline);
        }
    }
    return write_frame(c, op, false, payload, deadline);
}

// Send a text message.
pub fn send_text(c: Conn, text: str, deadline: until) -> result[bool, str] {
    return send_data(c, OP_TEXT, to_bytes(text), deadline);
}

// Send a text message given as bytes, checked to be UTF-8 first: for
// text holding U+0000, which a str cannot (it ends at the first zero
// byte), and for text already in a byte buffer.
pub fn send_text_bytes(c: Conn, data: bytes, deadline: until) -> result[bool, str] {
    if !unicode.valid_bytes(data) {
        return err("websocket: a text message must be UTF-8");
    }
    return send_data(c, OP_TEXT, data, deadline);
}

// Send a binary message.
pub fn send_binary(c: Conn, data: bytes, deadline: until) -> result[bool, str] {
    return send_data(c, OP_BINARY, data, deadline);
}

// Send a ping (payload up to 125 bytes); the server's pong is consumed by
// recv. options().ping_every sends them on a schedule instead.
pub fn ping(c: Conn, payload: bytes, deadline: until) -> result[bool, str] {
    if len(payload) > 125 {
        return err("websocket: a ping payload is at most 125 bytes");
    }
    let cr = check_open(c);
    guard let _c = cr else let e = err_of(cr) { return err(e); }
    return write_frame(c, OP_PING, false, payload, deadline);
}

// ---- reading -------------------------------------------------------------------------------

gc struct Frame {
    fin: bool,
    rsv1: bool,
    op: int,
    payload: bytes,
}

// The next message, or none when the deadline passes first (nothing is
// lost: a later call carries on). Pings are answered and pongs consumed
// on the way. A Close message means the server ended the connection; the
// handshake is answered and the next call is an error.
pub fn recv(c: Conn, deadline: until) -> result[opt[Message], str] {
    mutex_lock(c.slock);
    if c.state == ST_CLOSED {
        let why = c.why;
        mutex_unlock(c.slock);
        return err(why);
    }
    if c.reading {
        mutex_unlock(c.slock);
        return err("websocket: recv is already running in another task");
    }
    c.reading = true;
    mutex_unlock(c.slock);
    let r = read_message(c, deadline);
    mutex_lock(c.slock);
    c.reading = false;
    mutex_unlock(c.slock);
    return r;
}

// The text of a text message. A str ends at its first zero byte, so text
// holding U+0000 is cut there: m.data has every byte.
pub fn text(m: Message) -> str {
    return to_str(m.data);
}

fn read_message(c: Conn, deadline: until) -> result[opt[Message], str] {
    while true {
        let fr = read_frame(c, deadline);
        guard let got = fr else let e = err_of(fr) {
            if e == "timeout" {
                return ok(none);
            }
            let why = "websocket: read: " + e;
            if strings.has_prefix(e, "websocket: ") {
                why = e;
            }
            // if the connection was already ended (the keepalive gave
            // up, close_now, a failed write), that is the reason to give,
            // not the read it interrupted
            fail_now(c, why);
            return err(reason(c));
        }
        guard let f = got else { continue; }
        if f.op >= 8 {
            let cr = control(c, f, deadline);
            guard let m = cr else let e = err_of(cr) { return err(e); }
            if m.kind == Kind.Close {
                return ok(some(m));
            }
            continue;
        }
        let ar = assemble(c, f);
        guard let done = ar else let e = err_of(ar) { return err(e); }
        guard let m = done else { continue; }
        return ok(some(m));
    }
    return err("unreachable");
}

// One frame from the buffer, reading more as needed; none for a frame
// that carried nothing to act on. Errors that are the server's fault
// fail the connection with the matching close code.
fn read_frame(c: Conn, deadline: until) -> result[opt[Frame], str] {
    let hr = fill(c, 2, deadline);
    guard let _h = hr else let e = err_of(hr) { return err(e); }
    let b0 = c.data[c.pos];
    let b1 = c.data[c.pos + 1];
    let fin = (b0 & 128) != 0;
    let rsv1 = (b0 & 64) != 0;
    let op = b0 & 15;
    if (b0 & 48) != 0 {
        return protocol_error(c, 1002, "a reserved bit is set");
    }
    if rsv1 && (!c.deflate || op >= 8 || op == OP_CONT) {
        return protocol_error(c, 1002, "RSV1 set without a compressed message");
    }
    if (b1 & 128) != 0 {
        return protocol_error(c, 1002, "a server frame must not be masked");
    }
    if !(op == OP_CONT || op == OP_TEXT || op == OP_BINARY || op == OP_CLOSE || op == OP_PING || op == OP_PONG) {
        return protocol_error(c, 1002, "unknown opcode " + to_str(op));
    }
    let n = b1 & 127;
    let hl = 2;
    if n == 126 {
        hl = 4;
    } else if n == 127 {
        hl = 10;
    }
    if op >= 8 && (n > 125 || !fin) {
        return protocol_error(c, 1002, "a control frame must be whole and at most 125 bytes");
    }
    let lr = fill(c, hl, deadline);
    guard let _l = lr else let e = err_of(lr) { return err(e); }
    if n == 126 {
        n = (c.data[c.pos + 2] << 8) | c.data[c.pos + 3];
        if n < 126 {
            return protocol_error(c, 1002, "a length not in its shortest form");
        }
    } else if n == 127 {
        if (c.data[c.pos + 2] & 128) != 0 {
            return protocol_error(c, 1002, "a 64-bit length with its top bit set");
        }
        n = 0;
        for k in 0..8 {
            n = (n << 8) | c.data[c.pos + 2 + k];
        }
        if n < 65536 {
            return protocol_error(c, 1002, "a length not in its shortest form");
        }
    }
    // a data frame larger than any message we accept is refused before
    // its payload is read
    if op < 8 && c.frag_size + n > c.opts.max_message && !(rsv1 || c.frag_deflated) {
        return protocol_error(c, 1009, "a message over " + to_str(c.opts.max_message) + " bytes");
    }
    if op < 8 && n > c.opts.max_message {
        return protocol_error(c, 1009, "a frame over " + to_str(c.opts.max_message) + " bytes");
    }
    let pr = fill(c, hl + n, deadline);
    guard let _p = pr else let e = err_of(pr) { return err(e); }
    let start = c.pos + hl;
    let payload = c.data[start..start + n];
    c.pos = start + n;
    return ok(some(Frame { fin: fin, rsv1: rsv1, op: op, payload: payload }));
}

// A frame to a whole message: none while fragments are still coming.
fn assemble(c: Conn, f: Frame) -> result[opt[Message], str] {
    if f.op == OP_CONT {
        if c.frag_op < 0 {
            let pe: result[opt[Frame], str] = protocol_error(c, 1002, "a continuation with no message to continue");
            return err(err_of(pe));
        }
    } else if c.frag_op >= 0 {
        let pe: result[opt[Frame], str] = protocol_error(c, 1002, "a new message before the last one finished");
        return err(err_of(pe));
    }
    if f.op != OP_CONT && f.fin {
        // the common case: a whole message in one frame
        return finish_message(c, f.op, f.rsv1, f.payload);
    }
    if f.op != OP_CONT {
        c.frag_op = f.op;
        c.frag_deflated = f.rsv1;
        c.frag_parts = [];
        c.frag_size = 0;
        c.frag_carry = strings.bytes_zero(0);
    }
    if c.frag_op == OP_TEXT && !c.frag_deflated && !fragment_utf8_ok(c, f.payload, f.fin) {
        // fail fast: a broken character is refused as soon as it arrives,
        // not after the rest of a long message
        let pe: result[opt[Frame], str] = protocol_error(c, 1007, "a text message that is not UTF-8");
        return err(err_of(pe));
    }
    push(c.frag_parts, f.payload);
    c.frag_size += len(f.payload);
    if c.frag_size > c.opts.max_message {
        let pe: result[opt[Frame], str] = protocol_error(c, 1009, "a message over " + to_str(c.opts.max_message) + " bytes");
        return err(err_of(pe));
    }
    if !f.fin {
        return ok(none);
    }
    let data = strings.join_bytes(c.frag_parts, b"");
    let op = c.frag_op;
    let deflated = c.frag_deflated;
    c.frag_op = -1;
    c.frag_parts = [];
    c.frag_size = 0;
    return finish_message(c, op, deflated, data);
}

// Whether a text fragment is UTF-8 so far: what it carries over from the
// last fragment, then this one up to a character it leaves incomplete
// (kept for the next). The last fragment may leave nothing incomplete.
fn fragment_utf8_ok(c: Conn, frag: bytes, fin: bool) -> bool {
    let data = frag;
    if len(c.frag_carry) > 0 {
        let parts: [bytes] = [c.frag_carry, frag];
        data = strings.join_bytes(parts, b"");
    }
    let tail = incomplete_tail(data);
    if fin && tail > 0 {
        return false;
    }
    let whole = data;
    if tail > 0 {
        whole = data[0..len(data) - tail];
        c.frag_carry = data[len(data) - tail..];
        if !could_start_utf8(c.frag_carry) {
            return false;
        }
    } else {
        c.frag_carry = strings.bytes_zero(0);
    }
    return unicode.valid_bytes(whole);
}

// Whether an unfinished character could still become a valid one: its
// lead byte, and the range its second byte must fall in (RFC 3629's
// table: no overlong forms, no surrogates, nothing past U+10FFFF).
fn could_start_utf8(p: bytes) -> bool {
    let lead = p[0];
    if lead < 194 || lead > 244 {
        return false;
    }
    if len(p) < 2 {
        return true;
    }
    let b1 = p[1];
    if lead == 224 {
        return b1 >= 160 && b1 <= 191;
    }
    if lead == 237 {
        return b1 >= 128 && b1 <= 159;
    }
    if lead == 240 {
        return b1 >= 144 && b1 <= 191;
    }
    if lead == 244 {
        return b1 >= 128 && b1 <= 143;
    }
    return b1 >= 128 && b1 <= 191;
}

// How many bytes at the end of b begin a UTF-8 character that is not
// finished there (0 to 3).
fn incomplete_tail(b: bytes) -> int {
    let n = len(b);
    let i = n - 1;
    while i >= 0 && n - i < 4 && (b[i] & 192) == 128 {
        i -= 1;
    }
    if i < 0 {
        return 0;
    }
    let lead = b[i];
    let need = 1;
    if (lead & 224) == 192 {
        need = 2;
    } else if (lead & 240) == 224 {
        need = 3;
    } else if (lead & 248) == 240 {
        need = 4;
    }
    if n - i < need {
        return n - i;
    }
    return 0;
}

// The bytes after the compressed data that let a one-shot inflate end
// cleanly: the empty stored block a sync flush ends with (RFC 7692
// section 7.2.2 removes it in transit), then an empty final stored block.
fn deflate_tail() -> bytes {
    let t = strings.bytes_zero(9);
    t[2] = 255;
    t[3] = 255;
    t[4] = 1;
    t[7] = 255;
    t[8] = 255;
    return t;
}

fn finish_message(c: Conn, op: int, deflated: bool, data0: bytes) -> result[opt[Message], str] {
    let data = data0;
    if deflated {
        let parts: [bytes] = [data0, deflate_tail()];
        let ir = compress.inflate_raw(strings.join_bytes(parts, b""), c.opts.max_message);
        guard let plain = ir else let e = err_of(ir) {
            let code = 1007;
            if strings.contains(e, "limit") || strings.contains(e, "max") {
                code = 1009;
            }
            let pe: result[opt[Frame], str] = protocol_error(c, code, "a compressed message did not inflate: " + e);
            return err(err_of(pe));
        }
        data = plain;
    }
    if op == OP_TEXT {
        if !unicode.valid_bytes(data) {
            let pe: result[opt[Frame], str] = protocol_error(c, 1007, "a text message that is not UTF-8");
            return err(err_of(pe));
        }
        return ok(some(Message { kind: Kind.Text, data: data, code: 0, reason: "" }));
    }
    return ok(some(Message { kind: Kind.Binary, data: data, code: 0, reason: "" }));
}

// Ping, pong and close.
fn control(c: Conn, f: Frame, deadline: until) -> result[Message, str] {
    if f.op == OP_PING {
        mutex_lock(c.slock);
        let open = c.state == ST_OPEN;
        mutex_unlock(c.slock);
        if open {
            // a pong carries the ping's payload back (section 5.5.3); a
            // failed write fails the connection, which the next read sees
            write_frame(c, OP_PONG, false, f.payload, deadline);
        }
        return ok(Message { kind: Kind.Binary, data: f.payload, code: 0, reason: "" });
    }
    if f.op == OP_PONG {
        mutex_lock(c.slock);
        c.pings_unanswered = 0;
        mutex_unlock(c.slock);
        return ok(Message { kind: Kind.Binary, data: f.payload, code: 0, reason: "" });
    }
    // close: a code and a UTF-8 reason, or nothing
    let code = 1005;
    let reason = "";
    let p = f.payload;
    if len(p) == 1 {
        let pe: result[opt[Frame], str] = protocol_error(c, 1002, "a close frame with a one-byte body");
        return err(err_of(pe));
    }
    if len(p) >= 2 {
        code = (p[0] << 8) | p[1];
        if !valid_close_code(code) {
            let pe: result[opt[Frame], str] = protocol_error(c, 1002, "close code " + to_str(code) + " is not one a peer may send");
            return err(err_of(pe));
        }
        let rb = p[2..];
        if !unicode.valid_bytes(rb) {
            let pe: result[opt[Frame], str] = protocol_error(c, 1007, "a close reason that is not UTF-8");
            return err(err_of(pe));
        }
        reason = to_str(rb);
    }
    mutex_lock(c.slock);
    let was = c.state;
    c.state = ST_CLOSING;
    mutex_unlock(c.slock);
    if was == ST_OPEN {
        // answer with the same code (section 5.5.1); none for none
        let body = strings.bytes_zero(0);
        if code != 1005 {
            body = p[0..2];
        }
        write_frame(c, OP_CLOSE, false, body, deadline);
    }
    finish(c, "websocket: closed by the server (" + to_str(code) + close_suffix(reason) + ")");
    return ok(Message { kind: Kind.Close, data: p, code: code, reason: reason });
}

fn close_suffix(reason: str) -> str {
    if reason == "" {
        return "";
    }
    return " " + reason;
}

// The codes a close frame may carry (RFC 6455 section 7.4 and the IANA
// registry): 1000-1003, 1007-1014, and 3000-4999 for libraries and
// applications. 1004-1006 and 1015 are reserved never to be sent.
fn valid_close_code(code: int) -> bool {
    if code >= 1000 && code <= 1003 {
        return true;
    }
    if code >= 1007 && code <= 1014 {
        return true;
    }
    return code >= 3000 && code <= 4999;
}

// Fails the connection for something the server did wrong: a close frame
// with the code, best effort, then the socket is closed.
fn protocol_error(c: Conn, code: int, what: str) -> result[opt[Frame], str] {
    let why = "websocket: protocol error: " + what;
    mutex_lock(c.slock);
    let open = c.state == ST_OPEN;
    c.state = ST_CLOSING;
    mutex_unlock(c.slock);
    if open {
        let body = strings.bytes_zero(2);
        body[0] = (code >> 8) & 255;
        body[1] = code & 255;
        write_frame(c, OP_CLOSE, false, body, until_of(time.mono() + 1000000000));
    }
    finish(c, why);
    return err(why);
}

// Closes the socket and records why; later calls report it.
fn finish(c: Conn, why: str) {
    mutex_lock(c.slock);
    if c.state == ST_CLOSED {
        mutex_unlock(c.slock);
        return;
    }
    c.state = ST_CLOSED;
    c.why = why;
    mutex_unlock(c.slock);
    mutex_lock(c.wlock);
    close_transport(c);
    mutex_unlock(c.wlock);
}

fn fail_now(c: Conn, why: str) {
    finish(c, why);
}

// ---- closing ------------------------------------------------------------------------------

// The close handshake: send a close frame with code (1000 normal, or
// 3000-4999 for applications) and a reason of at most 123 bytes, then
// wait for the server's close (until deadline) and close the socket. If
// another task is in recv, that task sees the server's answer as a Close
// message and this call returns once the frame is sent.
pub fn close(c: Conn, code: int, reason: str, deadline: until) -> result[bool, str] {
    if !(code == 1000 || (code >= 3000 && code <= 4999) || (code >= 1001 && code <= 1003) ||
         (code >= 1007 && code <= 1014)) {
        return err("websocket: close code " + to_str(code) + " cannot be sent");
    }
    let rb = to_bytes(reason);
    if len(rb) > 123 {
        return err("websocket: a close reason is at most 123 bytes");
    }
    mutex_lock(c.slock);
    if c.state != ST_OPEN {
        let st = c.state;
        mutex_unlock(c.slock);
        if st == ST_CLOSED {
            return ok(true);
        }
        return err("websocket: already closing");
    }
    c.state = ST_CLOSING;
    let someone_reading = c.reading;
    if !someone_reading {
        c.reading = true;
    }
    mutex_unlock(c.slock);
    let body = strings.bytes_zero(2);
    body[0] = (code >> 8) & 255;
    body[1] = code & 255;
    let parts: [bytes] = [body, rb];
    let wr = write_frame(c, OP_CLOSE, false, strings.join_bytes(parts, b""), deadline);
    guard let _w = wr else let e = err_of(wr) {
        if !someone_reading {
            finish(c, "websocket: closed");
        }
        return err(e);
    }
    if someone_reading {
        return ok(true);
    }
    // read until the server's close (messages still in flight are dropped)
    let result_why = "";
    while true {
        let fr = read_frame(c, deadline);
        guard let got = fr else let e = err_of(fr) {
            if e != "timeout" && !strings.has_prefix(e, "connection closed") {
                result_why = e;
            }
            break;
        }
        guard let f = got else { continue; }
        if f.op == OP_CLOSE {
            break;
        }
    }
    mutex_lock(c.slock);
    c.reading = false;
    mutex_unlock(c.slock);
    finish(c, "websocket: closed");
    if result_why != "" && !strings.has_prefix(result_why, "websocket: protocol error") {
        return err("websocket: close: " + result_why);
    }
    return ok(true);
}

// Close the socket now, with no close handshake: for a connection that
// is already broken or must stop at once.
pub fn close_now(c: Conn) {
    finish(c, "websocket: closed");
}

// Whether the connection is open (not closing or closed).
pub fn is_open(c: Conn) -> bool {
    mutex_lock(c.slock);
    let open = c.state == ST_OPEN;
    mutex_unlock(c.slock);
    return open;
}

// Why the connection ended, or "" while it is open.
pub fn reason(c: Conn) -> str {
    mutex_lock(c.slock);
    let why = c.why;
    mutex_unlock(c.slock);
    return why;
}

// ---- keepalive --------------------------------------------------------------------------

// Sends a ping every ping_every, and fails the connection when one has
// gone a whole interval with no pong (any pong counts: the reader resets
// the count). The server's pongs arrive through recv, so a connection
// nobody reads cannot answer pings and is dropped -- read it, or leave
// ping_every at 0.
fn pinger(c: Conn) {
    let step = c.opts.ping_every;
    while true {
        let slept = 0;
        while slept < step {
            let nap = 50000000;
            if step - slept < nap {
                nap = step - slept;
            }
            time.sleep(nap);
            slept += nap;
            if !is_open(c) {
                return;
            }
        }
        mutex_lock(c.slock);
        let missed = c.pings_unanswered;
        c.pings_unanswered += 1;
        mutex_unlock(c.slock);
        if missed > 0 {
            finish(c, "websocket: no pong within " + to_str(step / 1000000) + " ms; the connection is dead");
            return;
        }
        let pr = write_frame(c, OP_PING, false, b"", until_of(time.mono() + step));
        guard let _p = pr else { return; }
    }
}
