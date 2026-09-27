// Redis client, speaking RESP2 over `net` (phase 2 connects; this
// phase is the pure protocol core: no sockets, no tasks).
//
// Like `pg`, this is written in slang rather than wrapping hiredis:
// a C call blocks the worker thread it runs on, while slang socket
// reads park the task on the reactor, so one pool serves many
// in-flight commands. And like `pg`, every fallible call returns
// `result[_, str]`, with server errors keeping Redis's own text:
//
//     WRONGTYPE Operation against a key holding the wrong kind of value
//
// A driver trusts the server with its memory: every length on the
// wire is the server's to choose. The MAX_* caps below bound what one
// bad or hostile server can make a program allocate. A reply that
// would exceed any of them is a protocol error, and (from phase 2) a
// connection that sees one is never used again.
//
// WHAT THIS DOES NOT DO, deliberately: RESP3 (HELLO, maps, sets,
// push messages on regular connections -- a later phase negotiates
// it once the core is proven), server-side sharding (CLUSTER/Sentinel
// routing is its own phase; `slot` below is the piece it builds on).

import "strings";
import "encoding";
import "net";

// ---- limits ----------------------------------------------------------

let MAX_LINE = 65536;        // one \r\n-terminated control line, 64 KiB
let MAX_BULK = 268435456;    // one bulk string, 256 MiB (server max is 512)
let MAX_ARRAY = 1000000;     // elements of one array reply
let MAX_DEPTH = 32;          // nested arrays (decode recurses)
let MAX_SLOTS = 16384;       // cluster hash slots, 0..16383

// ---- reply model -----------------------------------------------------

// The five RESP2 reply types. A reply is always one of exactly one.
pub let REPLY_SIMPLE = 0;   // +str           (text holds the text)
pub let REPLY_ERROR = 1;    // -err           (text holds the text)
pub let REPLY_INT = 2;      // :num           (num holds the value)
pub let REPLY_BULK = 3;     // $len\r\n<bytes> (bulk holds it, none when nil)
pub let REPLY_ARRAY = 4;    // *n\r\n...      (items holds them)

pub gc struct Reply {
    kind: int,
    text: str,           // simple-string and error text, "" otherwise
    num: int,            // integer replies, 0 otherwise
    bulk: opt[bytes],    // bulk data; none for a nil bulk ($-1)
    items: [Reply],      // array elements; [] when empty or nil
    is_nil: bool,        // a nil array (*-1); nil bulks use bulk == none
}

// A decoded reply plus how many bytes of the input it consumed, so a
// connection holding a read buffer knows what to keep.
pub gc struct Decoded {
    reply: Reply,
    consumed: int,
}

// ---- encoding --------------------------------------------------------

fn digit(n: int) -> int {
    return n + 48;
}

// Append a decimal integer to a byte buffer. Negative only for the
// RESP integer replies the server sends; command arities and bulk
// lengths are never negative.
fn write_int(buf: bytes, n: int) -> bytes {
    if n == 0 {
        return buf + b"0";
    }
    let neg = false;
    let v = n;
    if v < 0 {
        neg = true;
        v = 0 - v;
    }
    let digits: [int] = [];
    while v > 0 {
        push(digits, v % 10);
        v = v / 10;
    }
    if neg {
        buf = buf + b"-";
    }
    let i = len(digits) - 1;
    while i >= 0 {
        buf = buf + b" " ;
        buf[len(buf) - 1] = digit(digits[i]);
        i = i - 1;
    }
    return buf;
}

// Encode one command invocation as a RESP2 array of bulk strings:
//     SET key value  ->  *3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n
// Takes already-encoded argument bytes, so binary-safe values pass
// through untouched. Pure: no I/O, no allocation beyond the result.
pub fn encode(args: [bytes]) -> bytes {
    let out = b"";
    out = write_int(out, len(args));
    out = b"*" + out + b"\r\n";
    for a in args {
        out = out + b"$";
        out = write_int(out, len(a));
        out = out + b"\r\n" + a + b"\r\n";
    }
    return out;
}

// ---- decoding --------------------------------------------------------

// Internal parse result. done == false with err == "" means the input
// ends mid-message (incomplete); done == false with err set means the
// input is corrupt. Callers must not confuse the two: incomplete input
// waits for more bytes, corrupt input kills the connection.
gc struct parse_res {
    done: bool,
    reply: Reply,
    next: int,
    err: str,
}

fn blank_reply() -> Reply {
    return Reply { kind: -1, text: "", num: 0, bulk: none, items: [],
                   is_nil: false };
}

fn incomplete() -> parse_res {
    return parse_res { done: false, reply: blank_reply(), next: 0,
                       err: "" };
}

fn corrupt(msg: str) -> parse_res {
    return parse_res { done: false, reply: blank_reply(), next: 0,
                       err: msg };
}

// Index of the first \r\n at or after `from`, or -1 when the buffer
// ends first. -2 when the line is corrupt: past MAX_LINE, or a bare
// CR or LF (RESP lines end CRLF; a lone one is a violation, never a
// slow server). Control lines are short, so an over-long one is a
// hostile server too.
fn find_crlf(b: bytes, from: int) -> int {
    let i = from;
    while i + 1 < len(b) {
        if b[i] == 13 && b[i + 1] == 10 {
            return i;
        }
        if b[i] == 13 || b[i] == 10 {
            return -2;
        }
        if i - from + 1 > MAX_LINE {
            return -2;
        }
        i = i + 1;
    }
    // No CRLF in what arrived. A trailing LF is already decisive: on
    // the wire \r always precedes \n, so a final \n with no \r before
    // it is a bare LF, never a split line. A trailing \r may still be
    // half of a CRLF, so that alone waits for more bytes.
    if len(b) > from && b[len(b) - 1] == 10 {
        return -2;
    }
    return -1;
}

// Strict base-10 integer over buf[from..end]: optional leading `-`
// then digits only, fitting an int. Anything else is a protocol
// error carrying what was wrong.
fn parse_int(buf: bytes, from: int, end: int) -> result[int, str] {
    if from >= end {
        return err("empty integer");
    }
    let neg = false;
    let i = from;
    if buf[i] == 45 {
        neg = true;
        i = i + 1;
        if i >= end {
            return err("bare minus sign");
        }
    }
    let acc = 0;
    while i < end {
        let d = buf[i];
        if d < 48 || d > 57 {
            return err("not a base-10 integer");
        }
        let digit = d - 48;
        if neg {
            if acc < -922337203685477580 ||
               (acc == -922337203685477580 && digit > 8) {
                return err("integer out of range");
            }
            acc = acc * 10 - digit;
        } else {
            if acc > 922337203685477580 ||
               (acc == 922337203685477580 && digit > 7) {
                return err("integer out of range");
            }
            acc = acc * 10 + digit;
        }
        i = i + 1;
    }
    return ok(acc);
}

fn parse_value(buf: bytes, pos: int, depth: int) -> parse_res {
    if depth > MAX_DEPTH {
        return corrupt("array nesting exceeds limit");
    }
    if pos >= len(buf) {
        return incomplete();
    }
    let t = buf[pos];
    if t == 43 || t == 45 {
        // Simple strings and errors carry free text, not integers.
        let eol = find_crlf(buf, pos + 1);
        if eol == -1 {
            return incomplete();
        }
        if eol == -2 {
            return corrupt("bad control line");
        }
        let line = buf[pos + 1..eol];
        let kind = REPLY_SIMPLE;
        if t == 45 {
            kind = REPLY_ERROR;
        }
        return parse_res { done: true,
                           reply: Reply { kind: kind,
                                          text: to_str(line), num: 0,
                                          bulk: none, items: [],
                                          is_nil: false },
                           next: eol + 2, err: "" };
    }
    if t == 58 {
        let eol = find_crlf(buf, pos + 1);
        if eol == -1 {
            return incomplete();
        }
        if eol == -2 {
            return corrupt("bad control line");
        }
        let r = parse_int(buf, pos + 1, eol);
        guard let v = r else let e = err_of(r) {
            return corrupt("bad integer: " + e);
        }
        return parse_res { done: true,
                           reply: Reply { kind: REPLY_INT, text: "",
                                          num: v, bulk: none, items: [],
                                          is_nil: false },
                           next: eol + 2, err: "" };
    }
    if t == 36 {
        let eol = find_crlf(buf, pos + 1);
        if eol == -1 {
            return incomplete();
        }
        if eol == -2 {
            return corrupt("bad control line");
        }
        let r = parse_int(buf, pos + 1, eol);
        guard let n = r else let e = err_of(r) {
            return corrupt("bad bulk length: " + e);
        }
        if n == -1 {
            return parse_res { done: true,
                               reply: Reply { kind: REPLY_BULK, text: "",
                                              num: 0, bulk: none,
                                              items: [], is_nil: false },
                               next: eol + 2, err: "" };
        }
        if n < -1 {
            return corrupt("negative bulk length");
        }
        if n > MAX_BULK {
            return corrupt("bulk string exceeds limit");
        }
        if len(buf) < eol + 2 + n + 2 {
            return incomplete();
        }
        if buf[eol + 2 + n] != 13 || buf[eol + 2 + n + 1] != 10 {
            return corrupt("bulk string missing trailing CRLF");
        }
        return parse_res { done: true,
                           reply: Reply { kind: REPLY_BULK, text: "",
                                          num: 0,
                                          bulk: some(buf[eol + 2..
                                                         eol + 2 + n]),
                                          items: [], is_nil: false },
                           next: eol + 2 + n + 2, err: "" };
    }
    if t == 42 {
        let eol = find_crlf(buf, pos + 1);
        if eol == -1 {
            return incomplete();
        }
        if eol == -2 {
            return corrupt("bad control line");
        }
        let r = parse_int(buf, pos + 1, eol);
        guard let n = r else let e = err_of(r) {
            return corrupt("bad array length: " + e);
        }
        if n == -1 {
            let empty: [Reply] = [];
            return parse_res { done: true,
                               reply: Reply { kind: REPLY_ARRAY, text: "",
                                              num: 0, bulk: none,
                                              items: empty, is_nil: true },
                               next: eol + 2, err: "" };
        }
        if n < -1 {
            return corrupt("negative array length");
        }
        if n > MAX_ARRAY {
            return corrupt("array exceeds element limit");
        }
        let items: [Reply] = [];
        let at = eol + 2;
        let k = 0;
        while k < n {
            let sub = parse_value(buf, at, depth + 1);
            if !sub.done {
                if sub.err == "" {
                    return incomplete();
                }
                return sub;
            }
            push(items, sub.reply);
            at = sub.next;
            k = k + 1;
        }
        return parse_res { done: true,
                           reply: Reply { kind: REPLY_ARRAY, text: "",
                                          num: 0, bulk: none, items: items,
                                          is_nil: false },
                           next: at, err: "" };
    }
    return corrupt("unknown reply type");
}

// Decode one RESP2 reply from the front of `buf`. ok(none) means the
// buffer ends mid-message -- feed more bytes and retry. ok(some(d))
// consumed d.consumed bytes; anything after them is the next message.
// err means the bytes violate the protocol: never retry on the same
// connection.
pub fn decode(buf: bytes) -> result[opt[Decoded], str] {
    return decode_at(buf, 0);
}

// Decode one reply starting at `pos` instead of 0, for readers that
// keep one long-lived buffer and an offset into it (see Conn): no
// slicing, so no per-recv copy of everything already buffered.
// consumed counts from `pos`.
pub fn decode_at(buf: bytes, pos: int) -> result[opt[Decoded], str] {
    if pos < 0 || pos > len(buf) {
        return err("decode position out of range");
    }
    let r = parse_value(buf, pos, 0);
    if !r.done {
        if r.err == "" {
            let nothing: opt[Decoded] = none;
            return ok(nothing);
        }
        return err(r.err);
    }
    return ok(some(Decoded { reply: r.reply, consumed: r.next - pos }));
}

// ---- cluster hashing -------------------------------------------------

// CRC16-CCITT (poly 0x1021, init 0x0000), the exact algorithm Redis
// Cluster feeds key bytes through. Masked to 16 bits every step:
// slang integers are 64-bit and never wrap on their own.
fn crc16(data: bytes) -> int {
    let crc = 0;
    for byte in data {
        crc = (crc ^ (byte << 8)) & 65535;
        let i = 0;
        while i < 8 {
            if (crc & 32768) != 0 {
                crc = ((crc << 1) ^ 4129) & 65535;
            } else {
                crc = (crc << 1) & 65535;
            }
            i = i + 1;
        }
    }
    return crc;
}

// The hash slot of a key, 0..16383. `{...}` hash tags force colocation:
// only what sits between the first `{` and the next `}` is hashed.
// Empty tags hash the whole key, and a `{` with no `}` is literal.
pub fn slot(key: str) -> int {
    let kb = to_bytes(key);
    let open = -1;
    let i = 0;
    while i < len(kb) {
        if kb[i] == 123 {
            open = i;
            break;
        }
        i = i + 1;
    }
    if open >= 0 {
        let j = open + 1;
        while j < len(kb) {
            if kb[j] == 125 {
                if j == open + 1 {
                    break;
                }
                return crc16(kb[open + 1..j]) & (MAX_SLOTS - 1);
            }
            j = j + 1;
        }
    }
    return crc16(kb) & (MAX_SLOTS - 1);
}

// ---- configuration ---------------------------------------------------

pub gc struct Config {
    host: str,
    port: int,
    // ACL credentials; "" username with a password sends `AUTH <pass>`
    // (the pre-6 form), empty password sends no AUTH at all.
    username: str,
    password: str,
    // SELECTed after connecting. 0 is the default database.
    db: int,
    // "disable" or "require". "require" VERIFIES the certificate chain
    // and the hostname -- encryption without identity is not offered.
    sslmode: str,
    // A PEM bundle to verify the server against, or "" for the system
    // trust store.
    ca_path: str,
    // The TLS context, created on first use and shared by every
    // connection made from this Config -- loading a trust store per
    // connection costs milliseconds.
    tls_ctx: rawptr,
    // Pool and cluster phases read these; the codec ignores them.
    pool_size: int,
    // Nanoseconds. A server that answers nothing within io_timeout
    // breaks the connection rather than stalling the task forever.
    connect_timeout: int,
    io_timeout: int,
}

fn default_config(host: str, port: int) -> Config {
    return Config { host: host, port: port, username: "", password: "",
                    db: 0, sslmode: "disable", ca_path: "", pool_size: 8,
                    connect_timeout: 5000000000, io_timeout: 30000000,
                    tls_ctx: nullptr };
}

// The effective sslmode for a URL: the scheme default unless ?sslmode
// overrides it. rediss:// with sslmode=disable contradicts itself.
fn query_sslmode(query: str, tls: bool) -> result[str, str] {
    let mode = "disable";
    if tls {
        mode = "require";
    }
    if len(query) == 0 {
        return ok(mode);
    }
    let qv = encoding.query_get(query, "sslmode");
    guard let m = qv else {
        return ok(mode);
    }
    if m != "disable" && m != "require" {
        return err("sslmode must be disable or require");
    }
    if tls && m == "disable" {
        return err("rediss:// with sslmode=disable contradicts itself");
    }
    return ok(m);
}

// Parse redis://[[username:]password@]host[:port][/db][?sslmode=...].
// rediss:// forces sslmode=require. Percent-escapes in credentials
// and database decode the same way pg's URLs do.
pub fn parse_url(url: str) -> result[Config, str] {
    let tls = false;
    let rest = "";
    if strings.has_prefix(url, "redis://") {
        rest = strings.slice(url, 8, len(url));
    } else if strings.has_prefix(url, "rediss://") {
        rest = strings.slice(url, 9, len(url));
        tls = true;
    } else {
        return err("url must start with redis:// or rediss://");
    }
    let query = "";
    let q = strings.find(rest, "?");
    if q >= 0 {
        query = strings.slice(rest, q + 1, len(rest));
        rest = strings.slice(rest, 0, q);
    }
    let db = 0;
    let slash = strings.find(rest, "/");
    if slash >= 0 {
        let dr = encoding.url_decode(strings.slice(rest, slash + 1,
                                                   len(rest)));
        guard let d = dr else let e = err_of(dr) {
            return err("bad database in url: " + e);
        }
        let nr = to_int(d);
        guard let n = nr else {
            return err("database must be a number");
        }
        if n < 0 {
            return err("database must not be negative");
        }
        db = n;
        rest = strings.slice(rest, 0, slash);
    }
    let username = "";
    let password = "";
    let at = strings.rfind(rest, "@");
    if at >= 0 {
        let userinfo = strings.slice(rest, 0, at);
        rest = strings.slice(rest, at + 1, len(rest));
        let colon = strings.find(userinfo, ":");
        if colon >= 0 {
            let ur = encoding.url_decode(strings.slice(userinfo, 0,
                                                       colon));
            guard let u = ur else let e = err_of(ur) {
                return err("bad username in url: " + e);
            }
            username = u;
            let pr = encoding.url_decode(strings.slice(userinfo, colon + 1,
                                                       len(userinfo)));
            guard let p = pr else let e = err_of(pr) {
                return err("bad password in url: " + e);
            }
            password = p;
        } else {
            let ur = encoding.url_decode(userinfo);
            guard let u = ur else let e = err_of(ur) {
                return err("bad username in url: " + e);
            }
            username = u;
        }
    }
    let host = rest;
    let port = 6379;
    if strings.has_prefix(host, "[") {
        let close = strings.find(host, "]");
        if close < 0 {
            return err("bad IPv6 address in url");
        }
        let after = strings.slice(host, close + 1, len(host));
        host = strings.slice(host, 1, close);
        if len(after) > 0 {
            if !strings.has_prefix(after, ":") {
                return err("bad port in url");
            }
            let pr = to_int(strings.slice(after, 1, len(after)));
            guard let p = pr else {
                return err("port must be a number");
            }
            port = p;
        }
    } else {
        let colon = strings.rfind(host, ":");
        if colon >= 0 {
            let pr = to_int(strings.slice(host, colon + 1, len(host)));
            guard let p = pr else {
                return err("port must be a number");
            }
            port = p;
            host = strings.slice(host, 0, colon);
        }
    }
    if len(host) == 0 {
        return err("url has no host");
    }
    if port <= 0 || port > 65535 {
        return err("port out of range");
    }
    let sslmode = "disable";
    if tls {
        sslmode = "require";
    }
    if len(query) > 0 {
        let mr = query_sslmode(query, tls);
        guard let m = mr else let e = err_of(mr) {
            return err(e);
        }
        sslmode = m;
    }
    let c = default_config(host, port);
    c.username = username;
    c.password = password;
    c.db = db;
    c.sslmode = sslmode;
    return ok(c);
}

// ---- connections -----------------------------------------------------

// One server connection: exactly one round trip in flight at a time,
// serialized by lock. A Conn is safe to share between tasks; every
// public call below takes the lock for its whole exchange.
pub gc struct Conn {
    cfg: Config,
    fd: i32,
    ssl: rawptr,     // nullptr on cleartext
    buf: bytes,      // received and not yet consumed, from pos
    pos: int,
    lock: mutex,
    // Set when the connection can no longer be trusted to be at a
    // reply boundary: an I/O error, a timeout, a protocol violation.
    // A broken connection is never used again; `why` says what broke
    // it. Server-side command errors (WRONGTYPE and friends) do NOT
    // break it: exactly one reply was consumed either way.
    broken: bool,
    why: str,
    closed: bool,
}

fn tr_send(c: Conn, b: bytes, u: until) -> result[i32, str] {
    if c.ssl == nullptr {
        return net.send_until(c.fd, b, u);
    }
    return net.tls_send_until(c.ssl, b, u);
}

fn tr_recv(c: Conn, max: int, u: until) -> result[bytes, str] {
    if c.ssl == nullptr {
        return net.recv_until(c.fd, max, u);
    }
    return net.tls_recv_until(c.ssl, max, u);
}

fn tr_close(c: Conn) {
    if c.ssl == nullptr {
        net.close(c.fd);
        return;
    }
    net.tls_close(c.ssl);
}

fn mark_broken(c: Conn, why: str) {
    c.broken = true;
    c.why = why;
}

// Drop consumed bytes once they dominate the buffer, so a long-lived
// connection does not grow without bound. Amortized: each byte is
// copied at most twice per megabyte consumed.
fn compact(c: Conn) {
    if c.pos > 1048576 && c.pos * 2 > len(c.buf) {
        c.buf = c.buf[c.pos..];
        c.pos = 0;
    }
}

fn read_reply(c: Conn, deadline: until) -> result[Reply, str] {
    while true {
        let r = decode_at(c.buf, c.pos);
        guard let o = r else let e = err_of(r) {
            mark_broken(c, e);
            return err(e);
        }
        guard let d = o else {
            compact(c);
            let rr = tr_recv(c, 65536, deadline);
            guard let b = rr else let e = err_of(rr) {
                mark_broken(c, "recv: " + e);
                return err("recv: " + e);
            }
            if len(b) == 0 {
                mark_broken(c, "server closed the connection");
                return err("server closed the connection");
            }
            c.buf = c.buf + b;
            continue;
        }
        c.pos = c.pos + d.consumed;
        return ok(d.reply);
    }
}

// One command round trip. The caller must hold c.lock (every public
// call below does, except connect_config's own handshake on a conn
// nothing else can see yet). A server error reply is an err return,
// not a broken connection: the reply was fully consumed.
fn exchange(c: Conn, args: [bytes], deadline: until) -> result[Reply, str] {
    if c.closed {
        return err("connection is closed");
    }
    if c.broken {
        return err("connection is broken: " + c.why);
    }
    let wire = encode(args);
    let off = 0;
    while off < len(wire) {
        let sr = tr_send(c, wire[off..], deadline);
        guard let n = sr else let e = err_of(sr) {
            // A send that times out mid-write leaves the stream at an
            // unknown offset: the connection must go, not retry.
            mark_broken(c, "send: " + e);
            return err("send: " + e);
        }
        off = off + n;
    }
    let rr = read_reply(c, deadline);
    guard let r = rr else let e = err_of(rr) {
        return err(e);
    }
    if r.kind == REPLY_ERROR {
        return err(r.text);
    }
    return ok(r);
}

fn expect_ok(r: Reply, what: str) -> result[bool, str] {
    if r.kind == REPLY_SIMPLE {
        return ok(true);
    }
    return err(what + ": unexpected reply");
}

fn tls_ctx_of(cfg: Config) -> result[rawptr, str] {
    if cfg.tls_ctx != nullptr {
        return ok(cfg.tls_ctx);
    }
    let r = net.tls_client_ctx(cfg.ca_path);
    guard let ctx = r else let e = err_of(r) {
        return err(e);
    }
    cfg.tls_ctx = ctx;
    return ok(ctx);
}

// Open a connection from a parsed Config and run the handshake
// (AUTH when a password is set, SELECT when db is not 0). The
// deadline covers everything: DNS, TCP connect, TLS upgrade, login.
pub fn connect_config(cfg: Config, deadline: until) -> result[Conn, str] {
    if cfg.sslmode != "disable" && cfg.sslmode != "require" {
        return err("sslmode must be disable or require");
    }
    if cfg.port <= 0 || cfg.port > 65535 {
        return err("port out of range");
    }
    let dr = net.dial_until(cfg.host, cfg.port, deadline);
    guard let fd = dr else let e = err_of(dr) {
        return err("dial: " + e);
    }
    let ssl = nullptr;
    if cfg.sslmode == "require" {
        let cr = tls_ctx_of(cfg);
        guard let ctx = cr else let e = err_of(cr) {
            net.close(fd);
            return err(e);
        }
        // Direct TLS on a fresh socket: nothing was read before the
        // handshake, so there is nothing queued behind it to mistrust.
        let ur = net.tls_upgrade_until(fd, cfg.host, ctx, deadline);
        guard let s = ur else let e = err_of(ur) {
            net.close(fd);
            return err("tls: " + e);
        }
        ssl = s;
    }
    let c = Conn { cfg: cfg, fd: fd, ssl: ssl, buf: b"", pos: 0,
                   lock: make_mutex(), broken: false, why: "",
                   closed: false };
    if len(cfg.password) > 0 {
        let args: [bytes] = [to_bytes("AUTH"), to_bytes(cfg.password)];
        if len(cfg.username) > 0 {
            args = [to_bytes("AUTH"), to_bytes(cfg.username),
                    to_bytes(cfg.password)];
        }
        let ar = exchange(c, args, deadline);
        guard let r = ar else let e = err_of(ar) {
            tr_close(c);
            return err("auth: " + e);
        }
        guard let okv = expect_ok(r, "auth") else let e = err_of(expect_ok(r, "auth")) {
            tr_close(c);
            return err(e);
        }
    }
    if cfg.db != 0 {
        let sr = exchange(c, [to_bytes("SELECT"), to_bytes(to_str(cfg.db))],
                          deadline);
        guard let r = sr else let e = err_of(sr) {
            tr_close(c);
            return err("select: " + e);
        }
        guard let okv = expect_ok(r, "select") else let e = err_of(expect_ok(r, "select")) {
            tr_close(c);
            return err(e);
        }
    }
    return ok(c);
}

// Open a connection from a URL. See parse_url for the shape.
pub fn connect(url: str, deadline: until) -> result[Conn, str] {
    let cr = parse_url(url);
    guard let cfg = cr else let e = err_of(cr) {
        return err(e);
    }
    return connect_config(cfg, deadline);
}

// Run one command: args[0] is the command name. Exactly one reply is
// consumed, so at most one command is ever in flight per Conn; hold
// no lock of your own -- this takes c.lock for the round trip.
pub fn do(c: Conn, args: [bytes], deadline: until) -> result[Reply, str] {
    mutex_lock(c.lock);
    let r = exchange(c, args, deadline);
    mutex_unlock(c.lock);
    return r;
}

// Shut the connection down. In-flight calls on other tasks finish
// (or hit their own deadlines) first; close waits for the lock.
pub fn close(c: Conn) {
    mutex_lock(c.lock);
    if !c.closed {
        c.closed = true;
        tr_close(c);
    }
    mutex_unlock(c.lock);
}

// True while commands may still be attempted: not closed, not broken.
// A server-side idle close is discovered on use, which marks the
// connection broken then.
pub fn usable(c: Conn) -> bool {
    return !c.closed && !c.broken;
}
