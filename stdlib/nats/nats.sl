// A NATS client: publish, subscribe (plain and queue groups), headers,
// request/reply, flush and drain, keepalive, and automatic reconnection
// with resubscription. Core NATS, not JetStream.
//
//     import "nats";
//
//     let r = nats.connect("nats://127.0.0.1:4222", deadline);
//     guard let nc = r else let e = err_of(r) { panic(e); }
//     let sr = nats.subscribe(nc, "orders.*");
//     guard let sub = sr else let e = err_of(sr) { panic(e); }
//     nats.publish(nc, "orders.new", b"{\"id\":1}");
//     let m = nats.next_msg(sub, deadline);       // result[opt[Msg], str]
//     let reply = nats.request(nc, "pricing.quote", b"BTC", deadline);
//
// One connection carries every subscription. A reader task parses what
// the server sends and hands each message to its subscription's channel,
// so subscribers park instead of polling. A subscriber that falls more
// than `pending` messages behind loses the newest ones (counted in
// sub.dropped) rather than stalling every other subscription: the NATS
// "slow consumer" rule. Publishes append to one buffer that a flusher
// task writes out, so a burst of publishes becomes a few large writes.
//
// When the connection breaks, the reader reconnects (the URLs in turn,
// with jittered backoff), sends CONNECT and every live SUB again, and
// replays what was published meanwhile, up to reconnect_buffer bytes.

import "net";
import "json";
import "strings";
import "time";
import "rand";
import "builder";

// ---- options ------------------------------------------------------------------

pub gc struct Options {
    servers: [str],
    name: str,
    user: str,
    pass: str,
    token: str,
    nkey_seed: str,
    user_jwt: str,
    tls: bool,
    // TLS from the first byte, for a server with handshake_first; by
    // default the server sends INFO in clear and the client upgrades
    tls_first: bool,
    ca_path: str,
    pending: int,
    ping_interval: int,
    max_pings_out: int,
    reconnect: bool,
    max_reconnects: int,
    reconnect_wait: int,
    reconnect_buffer: int,
}

// Defaults for one server URL: nats://host:port, tls://host:port (TLS
// from the first byte) or nats://user:pass@host:port / nats://token@host.
pub fn options(url: str) -> Options {
    return Options {
        servers: [url],
        name: "",
        user: "",
        pass: "",
        token: "",
        nkey_seed: "",
        user_jwt: "",
        tls: false,
        tls_first: false,
        ca_path: "",
        pending: 1024,
        ping_interval: 120 * SECOND,
        max_pings_out: 2,
        reconnect: true,
        max_reconnects: 60,
        reconnect_wait: 2 * SECOND,
        reconnect_buffer: 8 * 1048576
    };
}

// Options with the user JWT and nkey seed of a .creds file.
pub fn with_creds(o: Options, creds_text: str) -> result[Options, str] {
    let r = parse_creds(creds_text);
    guard let parts = r else let e = err_of(r) { return err(e); }
    let check = nkey_seed_raw(parts[1]);
    guard let _s = check else let e = err_of(check) { return err(e); }
    o.user_jwt = parts[0];
    o.nkey_seed = parts[1];
    return ok(o);
}

// ---- the connection -------------------------------------------------------------

let SECOND = 1000000000;
let MAX_LINE = 4096;
let STATE_CONNECTED = 1;
let STATE_RECONNECTING = 2;
let STATE_CLOSED = 3;
let STATE_DRAINING = 4;

pub gc struct Msg {
    subject: str,
    reply: str,
    data: bytes,
    headers: map[str][str],
    // NATS status from the header line: 503 is "no responders"; 0 when none
    status: int,
}

pub gc struct Sub {
    sid: int,
    subject: str,
    queue: str,
    ch: chan[Msg],
    nc: Conn,
    max: int,
    delivered: int,
    dropped: int,
    closed: bool,
}

gc struct Waiter {
    deadline: until,
    wake: chan[bool],
    done: bool,
}

gc struct Server {
    host: str,
    port: int,
    tls: bool,
    user: str,
    pass: str,
    token: str,
}

pub gc struct Conn {
    opts: Options,
    servers: [Server],
    current: int,
    fd: int,
    ssl: rawptr,
    tls_ctx: rawptr,
    state: int,
    why: str,
    max_payload: int,
    headers_ok: bool,
    // writes: wlock guards the buffer (held for an append), iolock the
    // socket (held for a write), so a publisher never waits on a syscall
    wlock: mutex,
    iolock: mutex,
    out: builder.Bytes,
    kicked: bool,
    last_flush: int,
    kick: chan[bool],
    // subscriptions
    slock: mutex,
    subs: map[int]Sub,
    next_sid: int,
    // flush (PING/PONG) waiters, oldest first
    pongs: [chan[bool]],
    pings_out: int,
    // request/reply
    inbox: str,
    resp_sub: int,
    resp: map[str]chan[Msg],
    next_token: int,
    // deadline waiters, polled by the timer task
    waiters: [Waiter],
    tick: chan[bool],
    rng: rand.Rng,
    reconnects: int,
    // the reader task signals its exit here
    reader_done: chan[bool],
}

// Connect to url (see options).
pub fn connect(url: str, deadline: until) -> result[Conn, str] {
    return connect_with(options(url), deadline);
}

pub fn connect_with(o: Options, deadline: until) -> result[Conn, str] {
    if len(o.servers) == 0 {
        return err("nats: no server URL");
    }
    if o.pending < 1 || o.pending > 1048576 {
        return err("nats: pending must be 1 to 1048576 messages");
    }
    let servers: [Server] = [];
    for u in o.servers {
        let pr = parse_server(u);
        guard let s = pr else let e = err_of(pr) { return err(e); }
        if o.tls {
            s.tls = true;
        }
        push(servers, s);
    }
    let rr = rand.from_os();
    guard let rng = rr else let e = err_of(rr) { return err("nats: " + e); }
    let nc = Conn {
        opts: o, servers: servers, current: 0, fd: -1, ssl: nullptr,
        tls_ctx: nullptr, state: 0, why: "", max_payload: 1048576,
        headers_ok: false, wlock: make_mutex(), iolock: make_mutex(),
        out: builder.new_bytes(), kicked: false, last_flush: 0, kick: make_chan(1), slock: make_mutex(), subs: {}, next_sid: 1,
        pongs: [], pings_out: 0, inbox: "", resp_sub: 0, resp: {},
        next_token: 1, waiters: [], tick: make_chan(1), rng: rng,
        reconnects: 0, reader_done: make_chan(1)
    };
    nc.inbox = "_INBOX." + new_nuid(rng);
    // Try each server once at first connect.
    let last = "no server reachable";
    for i in 0..len(servers) {
        nc.current = i;
        let hr = handshake(nc, deadline);
        if let _ok = hr {
            nc.state = STATE_CONNECTED;
            spawn reader(nc);
            spawn flusher(nc);
            spawn timer(nc);
            spawn pinger(nc);
            return ok(nc);
        }
        last = err_of(hr);
    }
    return err(last);
}

fn parse_server(u: str) -> result[Server, str] {
    let s = Server { host: "", port: 4222, tls: false, user: "", pass: "", token: "" };
    let rest = u;
    if strings.has_prefix(u, "nats://") {
        rest = strings.slice(u, 7, len(u));
    } else if strings.has_prefix(u, "tls://") {
        rest = strings.slice(u, 6, len(u));
        s.tls = true;
    } else {
        return err("nats: URL must start with nats:// or tls://");
    }
    let at = strings.rfind(rest, "@");
    if at >= 0 {
        let cred = strings.slice(rest, 0, at);
        rest = strings.slice(rest, at + 1, len(rest));
        let colon = strings.find(cred, ":");
        if colon >= 0 {
            s.user = encoding_unescape(strings.slice(cred, 0, colon));
            s.pass = encoding_unescape(strings.slice(cred, colon + 1, len(cred)));
        } else {
            s.token = encoding_unescape(cred);
        }
    }
    let slash = strings.find(rest, "/");
    if slash >= 0 {
        rest = strings.slice(rest, 0, slash);
    }
    let colon = strings.rfind(rest, ":");
    if colon > 0 && !strings.has_suffix(rest, "]") {
        let pr = to_int(strings.slice(rest, colon + 1, len(rest)));
        guard let p = pr else { return err("nats: bad port in " + u); }
        if p < 1 || p > 65535 {
            return err("nats: bad port in " + u);
        }
        s.port = p;
        rest = strings.slice(rest, 0, colon);
    }
    if strings.has_prefix(rest, "[") && strings.has_suffix(rest, "]") {
        rest = strings.slice(rest, 1, len(rest) - 1);
    }
    if rest == "" {
        return err("nats: no host in " + u);
    }
    s.host = rest;
    return ok(s);
}

fn encoding_unescape(s: str) -> str {
    return strings.replace(strings.replace(s, "%40", "@"), "%3A", ":");
}

// 22 random base62 characters, as NATS inboxes use.
fn new_nuid(rng: rand.Rng) -> str {
    let alpha = to_bytes("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz");
    let out = strings.bytes_zero(22);
    for i in 0..22 {
        out[i] = alpha[rand.below(rng, 62)];
    }
    return strings.from_bytes(out, 0, 22);
}

// ---- the handshake ------------------------------------------------------------

struct Info {
    server_id: opt[str],
    max_payload: opt[int],
    headers: opt[bool],
    nonce: opt[str],
    tls_required: opt[bool],
    auth_required: opt[bool],
}

// Dial the current server, read INFO, send CONNECT and PING, and wait for
// the PONG that says the server accepted us. The reader is not running
// yet (or has stopped), so this reads the socket itself.
fn handshake(nc: Conn, deadline: until) -> result[bool, str] {
    let s = nc.servers[nc.current];
    let dr = net.dial_until(s.host, s.port, deadline);
    guard let fd = dr else let e = err_of(dr) {
        return err("nats: dial " + s.host + ":" + to_str(s.port) + ": " + e);
    }
    nc.fd = fd as int;
    nc.ssl = nullptr;
    if s.tls && nc.opts.tls_first {
        let ur = upgrade(nc, s, deadline);
        guard let _u = ur else let e = err_of(ur) {
            net.close(nc.fd);
            return err(e);
        }
    }
    let buf = RBuf { data: b"", pos: 0 };
    let lr = read_line(nc, buf, deadline);
    guard let first = lr else let e = err_of(lr) {
        close_transport(nc);
        return err(e);
    }
    if !strings.has_prefix(first, "INFO ") {
        close_transport(nc);
        return err("nats: expected INFO, got " + shorten(first));
    }
    let ir: result[Info, str] = json.decode(strings.slice(first, 5, len(first)));
    guard let info = ir else let e = err_of(ir) {
        close_transport(nc);
        return err("nats: bad INFO: " + e);
    }
    if (info.tls_required ?? false) && !s.tls {
        close_transport(nc);
        return err("nats: the server requires TLS: use tls:// or set tls");
    }
    if s.tls && nc.ssl == nullptr {
        // The usual NATS order: INFO in clear, then the TLS handshake,
        // then CONNECT (and any credentials) only over TLS. Bytes after
        // INFO before the handshake would be cleartext arriving where
        // TLS should be: refused.
        if buf.pos != len(buf.data) {
            close_transport(nc);
            return err("nats: unexpected data before the TLS handshake");
        }
        let ur = upgrade(nc, s, deadline);
        guard let _u = ur else let e = err_of(ur) {
            close_transport(nc);
            return err(e);
        }
    }
    nc.max_payload = info.max_payload ?? 1048576;
    nc.headers_ok = info.headers ?? false;
    let cr = connect_json(nc, s, info.nonce ?? "");
    guard let cj = cr else let e = err_of(cr) {
        close_transport(nc);
        return err(e);
    }
    let wr = write_now(nc, to_bytes("CONNECT " + cj + "\r\nPING\r\n"), deadline);
    guard let _w = wr else let e = err_of(wr) {
        close_transport(nc);
        return err(e);
    }
    // +OK is off (verbose false); the answer is PONG or -ERR.
    while true {
        let r = read_line(nc, buf, deadline);
        guard let line = r else let e = err_of(r) {
            close_transport(nc);
            return err(e);
        }
        if line == "PONG" {
            return ok(true);
        }
        if strings.has_prefix(line, "-ERR") {
            close_transport(nc);
            return err("nats: " + server_error(line));
        }
        if line == "PING" {
            write_now(nc, to_bytes("PONG\r\n"), deadline);
        }
        // INFO updates and +OK are fine to skip here.
    }
    return err("unreachable");
}

fn upgrade(nc: Conn, s: Server, deadline: until) -> result[bool, str] {
    if nc.tls_ctx == nullptr {
        let cr = net.tls_client_ctx(nc.opts.ca_path);
        guard let ctx = cr else let e = err_of(cr) {
            return err("nats: tls: " + e);
        }
        nc.tls_ctx = ctx;
    }
    let ur = net.tls_upgrade_until(nc.fd, s.host, nc.tls_ctx, deadline);
    guard let ssl = ur else let e = err_of(ur) {
        return err("nats: tls: " + e);
    }
    nc.ssl = ssl;
    return ok(true);
}

fn connect_json(nc: Conn, s: Server, nonce: str) -> result[str, str] {
    let o = nc.opts;
    let j = "{\"verbose\":false,\"pedantic\":false,\"lang\":\"slang\",\"version\":\"0.1.0\"," +
            "\"protocol\":1,\"headers\":true,\"no_responders\":true";
    if nc.ssl != nullptr {
        j = j + ",\"tls_required\":true";
    }
    if o.name != "" {
        j = j + ",\"name\":" + json.encode(o.name);
    }
    let user = s.user;
    let pass = s.pass;
    if o.user != "" {
        user = o.user;
        pass = o.pass;
    }
    if user != "" {
        j = j + ",\"user\":" + json.encode(user) + ",\"pass\":" + json.encode(pass);
    }
    let token = s.token;
    if o.token != "" {
        token = o.token;
    }
    if token != "" {
        j = j + ",\"auth_token\":" + json.encode(token);
    }
    if o.nkey_seed != "" {
        if nonce == "" {
            return err("nats: an nkey is configured but the server sent no nonce");
        }
        let sr = nkey_sign_nonce(o.nkey_seed, nonce);
        guard let sig = sr else let e = err_of(sr) { return err(e); }
        j = j + ",\"sig\":\"" + sig + "\"";
        if o.user_jwt != "" {
            j = j + ",\"jwt\":" + json.encode(o.user_jwt);
        } else {
            let pr = nkey_public(o.nkey_seed);
            guard let pk = pr else let e = err_of(pr) { return err(e); }
            j = j + ",\"nkey\":\"" + pk + "\"";
        }
    }
    return ok(j + "}");
}

fn server_error(line: str) -> str {
    let t = strings.trim(strings.slice(line, 4, len(line)));
    if strings.has_prefix(t, "'") && strings.has_suffix(t, "'") && len(t) >= 2 {
        t = strings.slice(t, 1, len(t) - 1);
    }
    return t;
}

fn shorten(s: str) -> str {
    if len(s) > 80 {
        return strings.slice(s, 0, 80) + "...";
    }
    return s;
}

// ---- transport ------------------------------------------------------------------

fn recv(nc: Conn, n: int, deadline: until) -> result[bytes, str] {
    if nc.ssl != nullptr {
        return net.tls_recv_until(nc.ssl, n, deadline);
    }
    return net.recv_until(nc.fd, n, deadline);
}

fn write_now(nc: Conn, data: bytes, deadline: until) -> result[bool, str] {
    let off = 0;
    while off < len(data) {
        let chunk = data;
        if off > 0 {
            chunk = data[off..];
        }
        let r = net_send(nc, chunk, deadline);
        guard let n = r else let e = err_of(r) {
            return err("nats: write: " + e);
        }
        if n <= 0 {
            return err("nats: write: connection closed");
        }
        off += n as int;
    }
    return ok(true);
}

fn net_send(nc: Conn, b: bytes, deadline: until) -> result[i32, str] {
    if nc.ssl != nullptr {
        return net.tls_send_until(nc.ssl, b, deadline);
    }
    return net.send_until(nc.fd, b, deadline);
}

fn close_transport(nc: Conn) {
    if nc.ssl != nullptr {
        net.tls_close(nc.ssl);
        nc.ssl = nullptr;
    }
    if nc.fd >= 0 {
        net.close(nc.fd);
        nc.fd = -1;
    }
}

// Bytes read but not yet parsed: data[pos..].
gc struct RBuf {
    data: bytes,
    pos: int,
}

// Add what was read. The parsed prefix is dropped as the new bytes are
// appended, so the buffer holds only what is still unparsed.
fn rbuf_add(rb: RBuf, b: bytes) {
    if rb.pos == len(rb.data) {
        rb.data = b;
        rb.pos = 0;
        return;
    }
    if rb.pos > 0 {
        rb.data = rb.data[rb.pos..] + b;
        rb.pos = 0;
        return;
    }
    rb.data = rb.data + b;
}

fn rbuf_more(nc: Conn, rb: RBuf, deadline: until) -> result[bool, str] {
    let r = recv(nc, 65536, deadline);
    guard let b = r else let e = err_of(r) {
        return err("nats: read: " + e);
    }
    if len(b) == 0 {
        return err("nats: connection closed by the server");
    }
    rbuf_add(rb, b);
    return ok(true);
}

// One CRLF-terminated line (handshake only; the reader parses in place).
fn read_line(nc: Conn, rb: RBuf, deadline: until) -> result[str, str] {
    while true {
        let nl = find_crlf(rb.data, rb.pos);
        if nl >= 0 {
            let line = strings.from_bytes(rb.data, rb.pos, nl);
            rb.pos = nl + 2;
            return ok(line);
        }
        if len(rb.data) - rb.pos > MAX_LINE {
            return err("nats: protocol line over 4 KiB");
        }
        let mr = rbuf_more(nc, rb, deadline);
        guard let _m = mr else let e = err_of(mr) { return err(e); }
    }
    return err("unreachable");
}

fn find_crlf(b: bytes, from: int) -> int {
    let i = from;
    while i + 1 < len(b) {
        if b[i] == 13 && b[i + 1] == 10 {
            return i;
        }
        i += 1;
    }
    return -1;
}

// ---- the reader task ------------------------------------------------------------

// Parses what the server sends and dispatches it, for the connection's
// life; on a broken connection it reconnects (or closes for good).
fn reader(nc: Conn) {
    let rb = RBuf { data: b"", pos: 0 };
    while true {
        if nc.state == STATE_CLOSED {
            break;
        }
        let pr = parse_frames(nc, rb);
        guard let _p = pr else let e = err_of(pr) {
            if nc.state == STATE_CLOSED {
                break;
            }
            nc.why = e;
            close_transport(nc);
            if !reconnect(nc) {
                shut_down(nc, e);
                break;
            }
            rb = RBuf { data: b"", pos: 0 };
            continue;
        }
        let mr = rbuf_more(nc, rb, until_never());
        guard let _m = mr else let e = err_of(mr) {
            if nc.state == STATE_CLOSED || nc.state == STATE_DRAINING && len(nc.subs) == 0 {
                break;
            }
            nc.why = e;
            close_transport(nc);
            if !reconnect(nc) {
                shut_down(nc, e);
                break;
            }
            rb = RBuf { data: b"", pos: 0 };
            continue;
        }
    }
    select {
        case chan_send(nc.reader_done, true) { }
        default { }
    }
}

// Handle every complete frame in rb; leave a partial one for the next
// read. An error is a protocol violation: the connection is dropped.
fn parse_frames(nc: Conn, rb: RBuf) -> result[bool, str] {
    while true {
        let nl = find_crlf(rb.data, rb.pos);
        if nl < 0 {
            if len(rb.data) - rb.pos > MAX_LINE {
                return err("nats: protocol line over 4 KiB");
            }
            return ok(true);
        }
        let b = rb.data;
        let start = rb.pos;
        let c0 = b[start];
        if c0 == 77 || c0 == 109 || c0 == 72 || c0 == 104 {
            // MSG / HMSG: the payload must be here too
            let hr = parse_msg_at(b, start, nl);
            guard let head = hr else let e = err_of(hr) { return err(e); }
            let body_start = nl + 2;
            if head.total > nc.max_payload + 65536 {
                return err("nats: message over the server's max_payload");
            }
            if len(b) < body_start + head.total + 2 {
                return ok(true);
            }
            let m = Msg { subject: head.subject, reply: head.reply, data: b"",
                          headers: {}, status: 0 };
            if head.hlen > 0 {
                let hb = strings.from_bytes(b, body_start, body_start + head.hlen);
                let pr = parse_headers(hb, m);
                guard let _h = pr else let e = err_of(pr) { return err(e); }
            }
            m.data = b[body_start + head.hlen..body_start + head.total];
            rb.pos = body_start + head.total + 2;
            deliver(nc, head.sid, m);
            continue;
        }
        let line = strings.from_bytes(b, start, nl);
        rb.pos = nl + 2;
        if line == "PING" {
            enqueue(nc, b"PONG\r\n");
        } else if line == "PONG" {
            got_pong(nc);
        } else if strings.has_prefix(line, "-ERR") {
            let why = server_error(line);
            // Permission errors leave the connection usable; others close it.
            if !strings.contains(strings.to_lower(why), "permissions violation") {
                return err("nats: " + why);
            }
            nc.why = why;
        } else if strings.has_prefix(line, "INFO") {
            let ir: result[Info, str] = json.decode(strings.slice(line, 5, len(line)));
            if let info = ir {
                nc.max_payload = info.max_payload ?? nc.max_payload;
            }
        } else if line != "+OK" && line != "" {
            return err("nats: unexpected " + shorten(line));
        }
    }
    return ok(true);
}

struct MsgHead {
    subject: str,
    sid: int,
    reply: str,
    hlen: int,
    total: int,
}

// "MSG subject sid [reply] size" or "HMSG subject sid [reply] hlen total",
// read in place from b[start..end): only the subject and reply become
// strs, the numbers are parsed from the bytes. This runs once per
// message received.
fn parse_msg_at(b: bytes, start: int, end: int) -> result[MsgHead, str] {
    let is_h = b[start] == 72 || b[start] == 104;
    // Token boundaries in locals, not a list: no allocation per message.
    // Tokens after the verb: subject, sid, then 1 to 3 more.
    let n = 0;
    let s1 = 0;
    let e1 = 0;
    let s2 = 0;
    let e2 = 0;
    let s3 = 0;
    let e3 = 0;
    let s4 = 0;
    let e4 = 0;
    let s5 = 0;
    let e5 = 0;
    let i = start;
    while i < end {
        while i < end && (b[i] == 32 || b[i] == 9) {
            i += 1;
        }
        if i >= end {
            break;
        }
        let ts = i;
        while i < end && b[i] != 32 && b[i] != 9 {
            i += 1;
        }
        if n == 1 { s1 = ts; e1 = i; }
        else if n == 2 { s2 = ts; e2 = i; }
        else if n == 3 { s3 = ts; e3 = i; }
        else if n == 4 { s4 = ts; e4 = i; }
        else if n == 5 { s5 = ts; e5 = i; }
        else if n > 5 { return err("nats: malformed message line"); }
        n += 1;
    }
    let want = 4;
    if is_h {
        want = 5;
    }
    if n < want || n > want + 1 {
        return err("nats: malformed message line");
    }
    let sid = dec_at(b, s2, e2);
    if sid < 0 {
        return err("nats: bad sid");
    }
    let reply = "";
    let total = -1;
    let hlen = 0;
    // the size fields are the last one (MSG) or two (HMSG)
    if n == 4 {
        total = dec_at(b, s3, e3);
    } else if n == 5 && !is_h {
        reply = strings.from_bytes(b, s3, e3);
        total = dec_at(b, s4, e4);
    } else if n == 5 {
        hlen = dec_at(b, s3, e3);
        total = dec_at(b, s4, e4);
    } else {
        reply = strings.from_bytes(b, s3, e3);
        hlen = dec_at(b, s4, e4);
        total = dec_at(b, s5, e5);
    }
    if total < 0 || hlen < 0 || hlen > total {
        return err("nats: bad message sizes");
    }
    return ok(MsgHead { subject: strings.from_bytes(b, s1, e1), sid: sid,
                        reply: reply, hlen: hlen, total: total });
}

// A non-negative decimal in b[s..e), or -1 (empty, a non-digit, or past
// ten digits, which no size or sid needs).
fn dec_at(b: bytes, s: int, e: int) -> int {
    if e <= s || e - s > 10 {
        return -1;
    }
    let v = 0;
    for i in s..e {
        let c = b[i];
        if c < 48 || c > 57 {
            return -1;
        }
        v = v * 10 + (c - 48);
    }
    return v;
}

// The str form, for tests and diagnostics.
fn parse_msg_head(line: str) -> result[MsgHead, str] {
    let b = to_bytes(line);
    return parse_msg_at(b, 0, len(b));
}

// "NATS/1.0[ status[ description]]\r\nKey: Value\r\n...\r\n\r\n"
fn parse_headers(h: str, m: Msg) -> result[bool, str] {
    let lines = strings.split(h, "\r\n");
    if len(lines) == 0 || !strings.has_prefix(lines[0], "NATS/1.0") {
        return err("nats: bad header block");
    }
    let first = strings.trim(strings.slice(lines[0], 8, len(lines[0])));
    if first != "" {
        let sp = strings.find(first, " ");
        let code = first;
        if sp > 0 {
            code = strings.slice(first, 0, sp);
        }
        m.status = to_int(code) ?? 0;
    }
    for i in 1..len(lines) {
        let l = lines[i];
        if l == "" {
            continue;
        }
        let c = strings.find(l, ":");
        if c <= 0 {
            return err("nats: bad header line");
        }
        let k = strings.trim(strings.slice(l, 0, c));
        let v = strings.trim(strings.slice(l, c + 1, len(l)));
        if has(m.headers, k) {
            let vs = m.headers[k];
            push(vs, v);
        } else {
            m.headers[k] = [v];
        }
    }
    return ok(true);
}

fn deliver(nc: Conn, sid: int, m: Msg) {
    mutex_lock(nc.slock);
    if sid == nc.resp_sub {
        let token = strings.slice(m.subject, len(nc.inbox) + 1, len(m.subject));
        if has(nc.resp, token) {
            let ch = nc.resp[token];
            del(nc.resp, token);
            mutex_unlock(nc.slock);
            select {
                case chan_send(ch, m) { }
                default { }
            }
            return;
        }
        mutex_unlock(nc.slock);
        return;
    }
    if !has(nc.subs, sid) {
        mutex_unlock(nc.slock);
        return;
    }
    let sub = nc.subs[sid];
    sub.delivered += 1;
    let last = sub.max > 0 && sub.delivered >= sub.max;
    if last {
        del(nc.subs, sid);
    }
    mutex_unlock(nc.slock);
    select {
        case chan_send(sub.ch, m) { }
        default { sub.dropped += 1; }
    }
    if last {
        finish_sub(sub);
    }
}

fn finish_sub(sub: Sub) {
    if !sub.closed {
        sub.closed = true;
        chan_close(sub.ch);
    }
}

// ---- writing ----------------------------------------------------------------------

// Queue bytes for the flusher. While reconnecting they wait, up to
// reconnect_buffer; past that, or once closed, an error.
fn enqueue(nc: Conn, b: bytes) -> result[bool, str] {
    mutex_lock(nc.wlock);
    if nc.state == STATE_CLOSED {
        mutex_unlock(nc.wlock);
        return err("nats: connection closed");
    }
    if nc.state == STATE_RECONNECTING &&
       nc.out.size() + len(b) > nc.opts.reconnect_buffer {
        mutex_unlock(nc.wlock);
        return err("nats: reconnecting and the reconnect buffer is full");
    }
    nc.out.write(b);
    let big = nc.out.size() >= 65536;
    // Only the first write after a flush wakes the flusher; the rest ride
    // along in the same write.
    let wake = !nc.kicked;
    nc.kicked = true;
    mutex_unlock(nc.wlock);
    if big && nc.state == STATE_CONNECTED {
        flush_out(nc);
        return ok(true);
    }
    if wake {
        select {
            case chan_send(nc.kick, true) { }
            default { }
        }
    }
    return ok(true);
}

// Write everything queued. The buffer lock is held only to take the
// buffer; the socket write happens under iolock alone.
fn flush_out(nc: Conn) {
    mutex_lock(nc.iolock);
    mutex_lock(nc.wlock);
    nc.kicked = false;
    if nc.state != STATE_CONNECTED && nc.state != STATE_DRAINING || nc.out.is_empty() {
        mutex_unlock(nc.wlock);
        mutex_unlock(nc.iolock);
        return;
    }
    let data = nc.out.take();
    nc.last_flush = len(data);
    mutex_unlock(nc.wlock);
    let wr = write_now(nc, data, until_of(time.mono() + 10 * SECOND));
    mutex_unlock(nc.iolock);
    if let _ok = wr {
        return;
    }
    // A failed write breaks the connection: the reader sees it and
    // reconnects. Shutting the socket wakes the reader's recv.
    close_transport(nc);
}

fn flusher(nc: Conn) {
    while nc.state != STATE_CLOSED {
        let k = chan_recv(nc.kick);
        if let _v = k {
            // A publisher in a loop fills the buffer far faster than one
            // write per message drains it, and taking the buffer from under
            // it on every message cost ~6 us each in wake-ups and lock
            // hand-offs. So wait for more first: 20 us after a light flush
            // (an occasional publish, sent almost at once), 200 us after a
            // heavy one (a stream, where batching is what matters). A
            // publisher that fills 32 KB first writes it itself.
            let window = 20000;
            if nc.last_flush >= 4096 {
                window = 200000;
            }
            if nc.out.size() < 32768 {
                time.sleep(window);
            }
            flush_out(nc);
        } else {
            break;
        }
    }
}

// ---- keepalive and deadlines -------------------------------------------------------

fn pinger(nc: Conn) {
    let step = 100000000;   // 100 ms, so close is noticed promptly
    let waited = 0;
    while nc.state != STATE_CLOSED {
        time.sleep(step);
        waited += step;
        if waited < nc.opts.ping_interval {
            continue;
        }
        waited = 0;
        if nc.state != STATE_CONNECTED {
            continue;
        }
        if nc.pings_out >= nc.opts.max_pings_out {
            nc.why = "nats: stale connection (no PONG)";
            close_transport(nc);
            continue;
        }
        nc.pings_out += 1;
        enqueue(nc, b"PING\r\n");
    }
}

fn got_pong(nc: Conn) {
    nc.pings_out = 0;
    mutex_lock(nc.slock);
    if len(nc.pongs) == 0 {
        mutex_unlock(nc.slock);
        return;
    }
    let ch = nc.pongs[0];
    let rest: [chan[bool]] = [];
    for i in 1..len(nc.pongs) {
        push(rest, nc.pongs[i]);
    }
    nc.pongs = rest;
    mutex_unlock(nc.slock);
    select {
        case chan_send(ch, true) { }
        default { }
    }
}

// Parked while nothing waits on a deadline; while something does, checks
// every 10 ms and wakes what has expired.
fn timer(nc: Conn) {
    while nc.state != STATE_CLOSED {
        mutex_lock(nc.slock);
        let any = len(nc.waiters) > 0;
        mutex_unlock(nc.slock);
        if !any {
            let t = chan_recv(nc.tick);
            if let _v = t {
                continue;
            }
            break;
        }
        time.sleep(10000000);
        mutex_lock(nc.slock);
        let keep: [Waiter] = [];
        for w in nc.waiters {
            if w.done {
                continue;
            }
            if until_hit(w.deadline) {
                w.done = true;
                select {
                    case chan_send(w.wake, true) { }
                    default { }
                }
            } else {
                push(keep, w);
            }
        }
        nc.waiters = keep;
        mutex_unlock(nc.slock);
    }
}

fn add_waiter(nc: Conn, deadline: until) -> Waiter {
    let w = Waiter { deadline: deadline, wake: make_chan(1), done: false };
    mutex_lock(nc.slock);
    push(nc.waiters, w);
    mutex_unlock(nc.slock);
    select {
        case chan_send(nc.tick, true) { }
        default { }
    }
    return w;
}

// ---- publishing -------------------------------------------------------------------

// Checked with string searches, not a copy to bytes: this runs on every
// publish.
fn check_subject(s: str, wild: bool) -> result[bool, str] {
    if s == "" || len(s) > 1024 {
        return err("nats: subject must be 1 to 1024 bytes");
    }
    if strings.contains(s, " ") || strings.contains(s, "\t") ||
       strings.contains(s, "\r") || strings.contains(s, "\n") {
        return err("nats: subject contains whitespace");
    }
    if !wild && (strings.contains(s, "*") || strings.contains(s, ">")) {
        return err("nats: wildcards are not allowed when publishing");
    }
    if strings.has_prefix(s, ".") || strings.has_suffix(s, ".") || strings.contains(s, "..") {
        return err("nats: subject has an empty token");
    }
    return ok(true);
}

pub fn publish(nc: Conn, subject: str, data: bytes) -> result[bool, str] {
    return publish_full(nc, subject, "", {}, data);
}

pub fn publish_reply(nc: Conn, subject: str, reply: str, data: bytes) -> result[bool, str] {
    return publish_full(nc, subject, reply, {}, data);
}

// Publish with headers (each key may carry several values).
pub fn publish_headers(nc: Conn, subject: str, headers: map[str][str], data: bytes)
                       -> result[bool, str] {
    return publish_full(nc, subject, "", headers, data);
}

pub fn publish_full(nc: Conn, subject: str, reply: str, headers: map[str][str],
                    data: bytes) -> result[bool, str] {
    let sc = check_subject(subject, false);
    guard let _s = sc else let e = err_of(sc) { return err(e); }
    if reply != "" {
        let rc = check_subject(reply, false);
        guard let _r = rc else let e = err_of(rc) { return err(e); }
    }
    let hb = "";
    if len(headers) > 0 {
        if !nc.headers_ok {
            return err("nats: the server does not support headers");
        }
        let hr = header_block(headers);
        guard let h = hr else let e = err_of(hr) { return err(e); }
        hb = h;
    }
    if len(hb) + len(data) > nc.max_payload {
        return err("nats: message over the server's max_payload of " + to_str(nc.max_payload));
    }
    return enqueue_pub(nc, subject, reply, hb, data);
}

// n >= 0 in decimal, written as bytes: no str allocated per publish.
fn write_dec(o: builder.Bytes, n: int) {
    if n < 10 {
        o.write_byte(48 + n);
        return;
    }
    let div = 1;
    while div <= n / 10 {
        div *= 10;
    }
    while div > 0 {
        o.write_byte(48 + (n / div) % 10);
        div /= 10;
    }
}

// The PUB/HPUB line, headers, payload and CRLF appended straight into the
// write buffer, in one lock and with no intermediate string.
fn enqueue_pub(nc: Conn, subject: str, reply: str, hb: str, data: bytes) -> result[bool, str] {
    let need = len(subject) + len(reply) + len(hb) + len(data) + 32;
    mutex_lock(nc.wlock);
    if nc.state == STATE_CLOSED {
        mutex_unlock(nc.wlock);
        return err("nats: connection closed");
    }
    if nc.state == STATE_RECONNECTING && nc.out.size() + need > nc.opts.reconnect_buffer {
        mutex_unlock(nc.wlock);
        return err("nats: reconnecting and the reconnect buffer is full");
    }
    let o = nc.out;
    if hb == "" {
        o.write_str("PUB ");
    } else {
        o.write_str("HPUB ");
    }
    o.write_str(subject);
    o.write_str(" ");
    if reply != "" {
        o.write_str(reply);
        o.write_str(" ");
    }
    if hb != "" {
        write_dec(o, len(hb));
        o.write_str(" ");
    }
    write_dec(o, len(hb) + len(data));
    o.write_str("\r\n");
    if hb != "" {
        o.write_str(hb);
    }
    o.write(data);
    o.write_str("\r\n");
    let big = nc.out.size() >= 65536;
    let wake = !nc.kicked;
    nc.kicked = true;
    mutex_unlock(nc.wlock);
    if big && nc.state == STATE_CONNECTED {
        flush_out(nc);
        return ok(true);
    }
    if wake {
        select {
            case chan_send(nc.kick, true) { }
            default { }
        }
    }
    return ok(true);
}

fn header_block(headers: map[str][str]) -> result[str, str] {
    let out = builder.new_str();
    out.write("NATS/1.0\r\n");
    for k, vs in headers {
        if k == "" || strings.contains(k, ":") || strings.contains(k, "\r") || strings.contains(k, "\n") {
            return err("nats: bad header name");
        }
        for v in vs {
            if strings.contains(v, "\r") || strings.contains(v, "\n") {
                return err("nats: header value contains a line break");
            }
            out.write(k).write(": ").write(v).write("\r\n");
        }
    }
    out.write("\r\n");
    return ok(out.finish());
}

// ---- subscribing ------------------------------------------------------------------

pub fn subscribe(nc: Conn, subject: str) -> result[Sub, str] {
    return queue_subscribe(nc, subject, "");
}

// Members of one queue group share the messages: each goes to one of them.
pub fn queue_subscribe(nc: Conn, subject: str, queue: str) -> result[Sub, str] {
    let sc = check_subject(subject, true);
    guard let _s = sc else let e = err_of(sc) { return err(e); }
    if queue != "" && (strings.contains(queue, " ") || strings.contains(queue, "\t")) {
        return err("nats: queue group contains whitespace");
    }
    if nc.state == STATE_CLOSED {
        return err("nats: connection closed");
    }
    mutex_lock(nc.slock);
    let sid = nc.next_sid;
    nc.next_sid += 1;
    let sub = Sub { sid: sid, subject: subject, queue: queue, ch: make_chan(nc.opts.pending),
                    nc: nc, max: 0, delivered: 0, dropped: 0, closed: false };
    nc.subs[sid] = sub;
    mutex_unlock(nc.slock);
    let r = enqueue(nc, to_bytes(sub_line(sub)));
    guard let _e = r else let e = err_of(r) { return err(e); }
    return ok(sub);
}

fn sub_line(sub: Sub) -> str {
    if sub.queue != "" {
        return "SUB " + sub.subject + " " + sub.queue + " " + to_str(sub.sid) + "\r\n";
    }
    return "SUB " + sub.subject + " " + to_str(sub.sid) + "\r\n";
}

// The next message, waiting until deadline: none when the deadline
// passes or the subscription has ended (unsubscribed, max reached,
// connection closed).
pub fn next_msg(sub: Sub, deadline: until) -> result[opt[Msg], str] {
    // a message already queued is taken without arming a timer
    select {
        case let m = chan_recv(sub.ch) {
            return ok(m);
        }
        default { }
    }
    if sub.closed {
        return ok(none);
    }
    let w = add_waiter(sub.nc, deadline);
    let out: opt[Msg] = none;
    select {
        case let m = chan_recv(sub.ch) {
            out = m;
        }
        case let _t = chan_recv(w.wake) { }
    }
    w.done = true;
    return ok(out);
}

pub fn unsubscribe(sub: Sub) -> result[bool, str] {
    let nc = sub.nc;
    mutex_lock(nc.slock);
    del(nc.subs, sub.sid);
    mutex_unlock(nc.slock);
    let r = enqueue(nc, to_bytes("UNSUB " + to_str(sub.sid) + "\r\n"));
    finish_sub(sub);
    return r;
}

// End the subscription by itself after max more messages.
pub fn auto_unsubscribe(sub: Sub, max: int) -> result[bool, str] {
    if max < 1 {
        return err("nats: max must be positive");
    }
    sub.max = sub.delivered + max;
    return enqueue(sub.nc, to_bytes("UNSUB " + to_str(sub.sid) + " " + to_str(max) + "\r\n"));
}

// ---- request/reply -------------------------------------------------------------------

// Publish data to subject with a fresh reply subject and wait for the
// first reply. "no responders" (status 503, when nothing listens) is an
// error at once instead of a timeout.
pub fn request(nc: Conn, subject: str, data: bytes, deadline: until) -> result[Msg, str] {
    return request_headers(nc, subject, {}, data, deadline);
}

pub fn request_headers(nc: Conn, subject: str, headers: map[str][str], data: bytes,
                       deadline: until) -> result[Msg, str] {
    mutex_lock(nc.slock);
    if nc.resp_sub == 0 {
        let sid = nc.next_sid;
        nc.next_sid += 1;
        nc.resp_sub = sid;
        mutex_unlock(nc.slock);
        let r = enqueue(nc, to_bytes("SUB " + nc.inbox + ".* " + to_str(sid) + "\r\n"));
        guard let _e = r else let e = err_of(r) { return err(e); }
        mutex_lock(nc.slock);
    }
    let token = to_str(nc.next_token);
    nc.next_token += 1;
    let ch: chan[Msg] = make_chan(1);
    nc.resp[token] = ch;
    mutex_unlock(nc.slock);
    let pr = publish_full(nc, subject, nc.inbox + "." + token, headers, data);
    guard let _p = pr else let e = err_of(pr) {
        mutex_lock(nc.slock);
        del(nc.resp, token);
        mutex_unlock(nc.slock);
        return err(e);
    }
    let w = add_waiter(nc, deadline);
    let got: opt[Msg] = none;
    select {
        case let m = chan_recv(ch) {
            got = m;
        }
        case let _t = chan_recv(w.wake) { }
    }
    w.done = true;
    guard let m = got else {
        mutex_lock(nc.slock);
        del(nc.resp, token);
        mutex_unlock(nc.slock);
        return err("nats: request timed out");
    }
    if m.status == 503 {
        return err("nats: no responders on " + subject);
    }
    return ok(m);
}

// Reply to a request message.
pub fn respond(nc: Conn, req: Msg, data: bytes) -> result[bool, str] {
    if req.reply == "" {
        return err("nats: the message has no reply subject");
    }
    return publish(nc, req.reply, data);
}

// ---- flush, drain, close ----------------------------------------------------------------

// Wait until the server has processed everything sent so far (a PING
// round trip).
pub fn flush(nc: Conn, deadline: until) -> result[bool, str] {
    let ch: chan[bool] = make_chan(1);
    mutex_lock(nc.slock);
    push(nc.pongs, ch);
    mutex_unlock(nc.slock);
    let r = enqueue(nc, b"PING\r\n");
    guard let _e = r else let e = err_of(r) { return err(e); }
    let w = add_waiter(nc, deadline);
    let ok_pong = false;
    select {
        case let v = chan_recv(ch) {
            ok_pong = v ?? false;
        }
        case let _t = chan_recv(w.wake) { }
    }
    w.done = true;
    if !ok_pong {
        return err("nats: flush timed out");
    }
    return ok(true);
}

// Unsubscribe everything, let what is in flight arrive, then close.
pub fn drain(nc: Conn, deadline: until) -> result[bool, str] {
    mutex_lock(nc.slock);
    let all: [Sub] = [];
    for sid, sub in nc.subs {
        push(all, sub);
    }
    mutex_unlock(nc.slock);
    for sub in all {
        enqueue(nc, to_bytes("UNSUB " + to_str(sub.sid) + "\r\n"));
    }
    let fr = flush(nc, deadline);
    nc.state = STATE_DRAINING;
    mutex_lock(nc.slock);
    nc.subs = {};
    mutex_unlock(nc.slock);
    for sub in all {
        finish_sub(sub);
    }
    close(nc);
    guard let _f = fr else let e = err_of(fr) { return err(e); }
    return ok(true);
}

pub fn close(nc: Conn) {
    if nc.state == STATE_CLOSED {
        return;
    }
    flush_out(nc);
    shut_down(nc, "nats: connection closed");
}

fn shut_down(nc: Conn, why: str) {
    nc.state = STATE_CLOSED;
    if nc.why == "" {
        nc.why = why;
    }
    close_transport(nc);
    mutex_lock(nc.slock);
    let subs: [Sub] = [];
    for sid, sub in nc.subs {
        push(subs, sub);
    }
    nc.subs = {};
    let pongs = nc.pongs;
    nc.pongs = [];
    let waiters = nc.waiters;
    nc.waiters = [];
    mutex_unlock(nc.slock);
    for sub in subs {
        finish_sub(sub);
    }
    for p in pongs {
        select {
            case chan_send(p, false) { }
            default { }
        }
    }
    for w in waiters {
        select {
            case chan_send(w.wake, true) { }
            default { }
        }
    }
    chan_close(nc.kick);
    chan_close(nc.tick);
}

// Why the connection is closed or last broke ("" while healthy).
pub fn last_error(nc: Conn) -> str {
    return nc.why;
}

pub fn is_connected(nc: Conn) -> bool {
    return nc.state == STATE_CONNECTED;
}

pub fn reconnects(nc: Conn) -> int {
    return nc.reconnects;
}

// ---- reconnecting -------------------------------------------------------------------------

// Try the servers in turn until one takes us, then resubscribe and replay
// the queued writes. False when reconnection is off or attempts run out.
fn reconnect(nc: Conn) -> bool {
    if !nc.opts.reconnect || nc.state == STATE_CLOSED || nc.state == STATE_DRAINING {
        return false;
    }
    nc.state = STATE_RECONNECTING;
    // Waiting flushes cannot be answered by the old connection.
    mutex_lock(nc.slock);
    let pongs = nc.pongs;
    nc.pongs = [];
    mutex_unlock(nc.slock);
    for p in pongs {
        select {
            case chan_send(p, false) { }
            default { }
        }
    }
    let attempt = 0;
    while attempt < nc.opts.max_reconnects && nc.state == STATE_RECONNECTING {
        let wait = rand.backoff(nc.rng, attempt, nc.opts.reconnect_wait / 4, nc.opts.reconnect_wait * 4);
        time.sleep(wait);
        nc.current = (nc.current + 1) % len(nc.servers);
        let hr = handshake(nc, until_of(time.mono() + 10 * SECOND));
        if let _ok = hr {
            // Resubscribe ahead of the writes queued while away.
            mutex_lock(nc.slock);
            let subs: [Sub] = [];
            for sid, sub in nc.subs {
                push(subs, sub);
            }
            let resp_sid = nc.resp_sub;
            mutex_unlock(nc.slock);
            let w = builder.new_bytes();
            for sub in subs {
                w.write_str(sub_line(sub));
                if sub.max > 0 {
                    w.write_str("UNSUB " + to_str(sub.sid) + " " + to_str(sub.max - sub.delivered) + "\r\n");
                }
            }
            if resp_sid != 0 {
                w.write_str("SUB " + nc.inbox + ".* " + to_str(resp_sid) + "\r\n");
            }
            mutex_lock(nc.iolock);
            mutex_lock(nc.wlock);
            let queued = nc.out.take();
            nc.kicked = false;
            mutex_unlock(nc.wlock);
            let wr = write_now(nc, w.finish() + queued, until_of(time.mono() + 10 * SECOND));
            mutex_unlock(nc.iolock);
            if let _w = wr {
                nc.pings_out = 0;
                nc.reconnects += 1;
                nc.why = "";
                nc.state = STATE_CONNECTED;
                return true;
            }
            close_transport(nc);
        }
        attempt += 1;
    }
    return false;
}
