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
import "time";
import "crypto";

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
    // Pool bookkeeping: true while checked out of a Pool (double
    // release panics), and what the connection is in the middle of --
    // 0 nothing, 1 MULTI (transactions never return to the pool).
    in_pool: bool,
    mode: int,
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

// Send everything: a short write retries with what is left, exactly
// like exchange. A timeout mid-write desyncs the stream, so any
// failure breaks the connection.
fn send_all(c: Conn, b: bytes, deadline: until) -> result[bool, str] {
    let off = 0;
    while off < len(b) {
        let sr = tr_send(c, b[off..], deadline);
        guard let n = sr else let e = err_of(sr) {
            mark_broken(c, "send: " + e);
            return err("send: " + e);
        }
        off = off + n;
    }
    return ok(true);
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
    let wr = send_all(c, wire, deadline);
    guard let sent = wr else let e = err_of(wr) {
        return err(e);
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
                   closed: false, in_pool: false, mode: 0 };
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
// Refused inside MULTI: queued commands answer +QUEUED, which no
// typed shape could read -- use queue there.
pub fn do(c: Conn, args: [bytes], deadline: until) -> result[Reply, str] {
    mutex_lock(c.lock);
    if c.mode == 1 {
        mutex_unlock(c.lock);
        return err("inside MULTI: queue commands with queue");
    }
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

// ---- reply shaping ---------------------------------------------------
// Typed commands are all one round trip plus one of these extractors:
// a reply of the wrong shape is a client-side error naming the
// command, never a silent misread.

fn as_int(r: Reply, what: str) -> result[int, str] {
    if r.kind != REPLY_INT {
        return err(what + ": expected an integer reply");
    }
    return ok(r.num);
}

fn as_int_bool(r: Reply, what: str) -> result[bool, str] {
    if r.kind != REPLY_INT {
        return err(what + ": expected an integer reply");
    }
    if r.num == 1 {
        return ok(true);
    }
    if r.num == 0 {
        return ok(false);
    }
    return err(what + ": expected 0 or 1");
}

fn as_simple(r: Reply, what: str) -> result[str, str] {
    if r.kind != REPLY_SIMPLE {
        return err(what + ": expected a status reply");
    }
    return ok(r.text);
}

fn as_bulk(r: Reply, what: str) -> result[bytes, str] {
    if r.kind != REPLY_BULK {
        return err(what + ": expected a bulk reply");
    }
    guard let b = r.bulk else {
        return err(what + ": unexpected nil");
    }
    return ok(b);
}

fn as_array(r: Reply, what: str) -> result[[Reply], str] {
    if r.kind != REPLY_ARRAY {
        return err(what + ": expected an array reply");
    }
    if r.is_nil {
        return err(what + ": unexpected nil");
    }
    return ok(r.items);
}

fn cmd2(c: Conn, name: str, a: bytes, deadline: until) -> result[Reply, str] {
    return do(c, [to_bytes(name), a], deadline);
}

// ---- strings ---------------------------------------------------------

// PING, expecting PONG back.
pub fn ping(c: Conn, deadline: until) -> result[str, str] {
    let r = do(c, [to_bytes("PING")], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_simple(reply, "PING");
}

// ECHO, expecting the value back byte-identical.
pub fn echo(c: Conn, v: bytes, deadline: until) -> result[bytes, str] {
    let r = cmd2(c, "ECHO", v, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_bulk(reply, "ECHO");
}

// GET: the value, or none when the key is absent. A missing key is
// absent data (opt), not an error.
pub fn get(c: Conn, key: str, deadline: until) -> result[opt[bytes], str] {
    let r = cmd2(c, "GET", to_bytes(key), deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind != REPLY_BULK {
        return err("GET: expected a bulk reply");
    }
    return ok(reply.bulk);
}

// SET: true when the server answers +OK.
pub fn set(c: Conn, key: str, val: bytes,
           deadline: until) -> result[bool, str] {
    let r = do(c, [to_bytes("SET"), to_bytes(key), val], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind != REPLY_SIMPLE {
        return err("SET: expected a status reply");
    }
    return ok(true);
}

// SET with a TTL in seconds. True on +OK.
pub fn set_ex(c: Conn, key: str, seconds: int, val: bytes,
              deadline: until) -> result[bool, str] {
    let r = do(c, [to_bytes("SET"), to_bytes(key), val, to_bytes("EX"),
                   to_bytes(to_str(seconds))], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind != REPLY_SIMPLE {
        return err("SET: expected a status reply");
    }
    return ok(true);
}

// SETNX: true when the key was absent and is now set.
pub fn set_nx(c: Conn, key: str, val: bytes,
              deadline: until) -> result[bool, str] {
    let r = do(c, [to_bytes("SETNX"), to_bytes(key), val], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int_bool(reply, "SETNX");
}

// DEL_KEYS: how many of the keys existed. Named with a suffix
// because `del` itself removes map entries -- it is a builtin.
pub fn del_keys(c: Conn, keys: [str], deadline: until) -> result[int, str] {
    let args: [bytes] = [to_bytes("DEL")];
    for k in keys {
        push(args, to_bytes(k));
    }
    let r = do(c, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "DEL");
}

// EXISTS: how many of the keys exist.
pub fn exists(c: Conn, keys: [str], deadline: until) -> result[int, str] {
    let args: [bytes] = [to_bytes("EXISTS")];
    for k in keys {
        push(args, to_bytes(k));
    }
    let r = do(c, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "EXISTS");
}

// EXPIRE: true when the timeout was set (false: missing key).
pub fn expire(c: Conn, key: str, seconds: int,
              deadline: until) -> result[bool, str] {
    let r = do(c, [to_bytes("EXPIRE"), to_bytes(key),
                   to_bytes(to_str(seconds))], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int_bool(reply, "EXPIRE");
}

// PEXPIRE: like EXPIRE with a millisecond TTL.
pub fn pexpire(c: Conn, key: str, ms: int,
               deadline: until) -> result[bool, str] {
    let r = do(c, [to_bytes("PEXPIRE"), to_bytes(key),
                   to_bytes(to_str(ms))], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int_bool(reply, "PEXPIRE");
}

// TTL in seconds: -2 missing key, -1 no TTL, else seconds left.
pub fn ttl(c: Conn, key: str, deadline: until) -> result[int, str] {
    let r = cmd2(c, "TTL", to_bytes(key), deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "TTL");
}

// PTTL: like TTL in milliseconds.
pub fn pttl(c: Conn, key: str, deadline: until) -> result[int, str] {
    let r = cmd2(c, "PTTL", to_bytes(key), deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "PTTL");
}

// PERSIST: true when a TTL was removed (false: missing key or none).
pub fn persist(c: Conn, key: str, deadline: until) -> result[bool, str] {
    let r = cmd2(c, "PERSIST", to_bytes(key), deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int_bool(reply, "PERSIST");
}

// INCR/DECR: the value after the change.
pub fn incr(c: Conn, key: str, deadline: until) -> result[int, str] {
    let r = cmd2(c, "INCR", to_bytes(key), deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "INCR");
}

pub fn decr(c: Conn, key: str, deadline: until) -> result[int, str] {
    let r = cmd2(c, "DECR", to_bytes(key), deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "DECR");
}

pub fn incr_by(c: Conn, key: str, n: int,
               deadline: until) -> result[int, str] {
    let r = do(c, [to_bytes("INCRBY"), to_bytes(key),
                   to_bytes(to_str(n))], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "INCRBY");
}

pub fn decr_by(c: Conn, key: str, n: int,
               deadline: until) -> result[int, str] {
    let r = do(c, [to_bytes("DECRBY"), to_bytes(key),
                   to_bytes(to_str(n))], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "DECRBY");
}

// APPEND: the length after appending. STRLEN: the current length.
pub fn append(c: Conn, key: str, val: bytes,
              deadline: until) -> result[int, str] {
    let r = do(c, [to_bytes("APPEND"), to_bytes(key), val], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "APPEND");
}

pub fn strlen(c: Conn, key: str, deadline: until) -> result[int, str] {
    let r = cmd2(c, "STRLEN", to_bytes(key), deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "STRLEN");
}

// MGET: one slot per key, none for the missing ones.
pub fn mget(c: Conn, keys: [str],
            deadline: until) -> result[[opt[bytes]], str] {
    let args: [bytes] = [to_bytes("MGET")];
    for k in keys {
        push(args, to_bytes(k));
    }
    let r = do(c, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    guard let items = as_array(reply, "MGET") else let e = err_of(as_array(reply, "MGET")) {
        return err(e);
    }
    let out: [opt[bytes]] = [];
    for it in items {
        if it.kind != REPLY_BULK {
            return err("MGET: expected bulk elements");
        }
        push(out, it.bulk);
    }
    return ok(out);
}

// MSET: field iteration order is insertion order, so the wire order
// is deterministic for a literally-built map.
pub fn mset(c: Conn, kv: map[str]bytes,
            deadline: until) -> result[bool, str] {
    let args: [bytes] = [to_bytes("MSET")];
    for k, v in kv {
        push(args, to_bytes(k));
        push(args, v);
    }
    let r = do(c, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind != REPLY_SIMPLE {
        return err("MSET: expected a status reply");
    }
    return ok(true);
}

// ---- hashes ----------------------------------------------------------

// HSET: how many fields were newly added.
pub fn hset(c: Conn, key: str, field: str, val: bytes,
            deadline: until) -> result[int, str] {
    let r = do(c, [to_bytes("HSET"), to_bytes(key), to_bytes(field), val],
               deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "HSET");
}

// HGET: the value, or none when key or field is absent.
pub fn hget(c: Conn, key: str, field: str,
            deadline: until) -> result[opt[bytes], str] {
    let r = do(c, [to_bytes("HGET"), to_bytes(key), to_bytes(field)],
               deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind != REPLY_BULK {
        return err("HGET: expected a bulk reply");
    }
    return ok(reply.bulk);
}

// HGETALL: the whole hash. Field names decode to str; binary field
// names a program did not put there itself come back lossy.
pub fn hgetall(c: Conn, key: str,
               deadline: until) -> result[map[str]bytes, str] {
    let r = cmd2(c, "HGETALL", to_bytes(key), deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    guard let items = as_array(reply, "HGETALL") else let e = err_of(as_array(reply, "HGETALL")) {
        return err(e);
    }
    if len(items) % 2 != 0 {
        return err("HGETALL: odd element count");
    }
    let out: map[str]bytes = {};
    let i = 0;
    while i < len(items) {
        if items[i].kind != REPLY_BULK || items[i + 1].kind != REPLY_BULK {
            return err("HGETALL: expected bulk elements");
        }
        guard let f = items[i].bulk else {
            return err("HGETALL: nil field");
        }
        guard let v = items[i + 1].bulk else {
            return err("HGETALL: nil value");
        }
        out[to_str(f)] = v;
        i = i + 2;
    }
    return ok(out);
}

// HDEL: how many fields were removed.
pub fn hdel(c: Conn, key: str, fields: [str],
            deadline: until) -> result[int, str] {
    let args: [bytes] = [to_bytes("HDEL"), to_bytes(key)];
    for f in fields {
        push(args, to_bytes(f));
    }
    let r = do(c, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "HDEL");
}

pub fn hexists(c: Conn, key: str, field: str,
               deadline: until) -> result[bool, str] {
    let r = do(c, [to_bytes("HEXISTS"), to_bytes(key), to_bytes(field)],
               deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int_bool(reply, "HEXISTS");
}

pub fn hkeys(c: Conn, key: str,
             deadline: until) -> result[[str], str] {
    let r = cmd2(c, "HKEYS", to_bytes(key), deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    guard let items = as_array(reply, "HKEYS") else let e = err_of(as_array(reply, "HKEYS")) {
        return err(e);
    }
    let out: [str] = [];
    for it in items {
        if it.kind != REPLY_BULK {
            return err("HKEYS: expected bulk elements");
        }
        guard let b = it.bulk else {
            return err("HKEYS: nil element");
        }
        push(out, to_str(b));
    }
    return ok(out);
}

pub fn hvals(c: Conn, key: str,
             deadline: until) -> result[[bytes], str] {
    let r = cmd2(c, "HVALS", to_bytes(key), deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    guard let items = as_array(reply, "HVALS") else let e = err_of(as_array(reply, "HVALS")) {
        return err(e);
    }
    let out: [bytes] = [];
    for it in items {
        if it.kind != REPLY_BULK {
            return err("HVALS: expected bulk elements");
        }
        guard let b = it.bulk else {
            return err("HVALS: nil element");
        }
        push(out, b);
    }
    return ok(out);
}

pub fn hlen(c: Conn, key: str, deadline: until) -> result[int, str] {
    let r = cmd2(c, "HLEN", to_bytes(key), deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "HLEN");
}

pub fn hincr_by(c: Conn, key: str, field: str, n: int,
                deadline: until) -> result[int, str] {
    let r = do(c, [to_bytes("HINCRBY"), to_bytes(key), to_bytes(field),
                   to_bytes(to_str(n))], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "HINCRBY");
}

// ---- lists -----------------------------------------------------------

fn push_int_cmd(c: Conn, name: str, key: str, vals: [bytes],
                deadline: until) -> result[int, str] {
    let args: [bytes] = [to_bytes(name), to_bytes(key)];
    for v in vals {
        push(args, v);
    }
    let r = do(c, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, name);
}

// LPUSH/RPUSH: the length after pushing.
pub fn lpush(c: Conn, key: str, vals: [bytes],
             deadline: until) -> result[int, str] {
    return push_int_cmd(c, "LPUSH", key, vals, deadline);
}

pub fn rpush(c: Conn, key: str, vals: [bytes],
             deadline: until) -> result[int, str] {
    return push_int_cmd(c, "RPUSH", key, vals, deadline);
}

// LPOP/RPOP: the element, or none when the list is absent or drained.
pub fn lpop(c: Conn, key: str, deadline: until) -> result[opt[bytes], str] {
    let r = cmd2(c, "LPOP", to_bytes(key), deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind != REPLY_BULK {
        return err("LPOP: expected a bulk reply");
    }
    return ok(reply.bulk);
}

pub fn rpop(c: Conn, key: str, deadline: until) -> result[opt[bytes], str] {
    let r = cmd2(c, "RPOP", to_bytes(key), deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind != REPLY_BULK {
        return err("RPOP: expected a bulk reply");
    }
    return ok(reply.bulk);
}

pub fn llen(c: Conn, key: str, deadline: until) -> result[int, str] {
    let r = cmd2(c, "LLEN", to_bytes(key), deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "LLEN");
}

// LRANGE: elements from start to stop inclusive; negative indexes
// count from the tail, exactly as Redis documents.
pub fn lrange(c: Conn, key: str, start: int, stop: int,
              deadline: until) -> result[[bytes], str] {
    let r = do(c, [to_bytes("LRANGE"), to_bytes(key),
                   to_bytes(to_str(start)), to_bytes(to_str(stop))],
               deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    guard let items = as_array(reply, "LRANGE") else let e = err_of(as_array(reply, "LRANGE")) {
        return err(e);
    }
    let out: [bytes] = [];
    for it in items {
        if it.kind != REPLY_BULK {
            return err("LRANGE: expected bulk elements");
        }
        guard let b = it.bulk else {
            return err("LRANGE: nil element");
        }
        push(out, b);
    }
    return ok(out);
}

pub fn ltrim(c: Conn, key: str, start: int, stop: int,
             deadline: until) -> result[bool, str] {
    let r = do(c, [to_bytes("LTRIM"), to_bytes(key),
                   to_bytes(to_str(start)), to_bytes(to_str(stop))],
               deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind != REPLY_SIMPLE {
        return err("LTRIM: expected a status reply");
    }
    return ok(true);
}

pub fn lindex(c: Conn, key: str, i: int,
              deadline: until) -> result[opt[bytes], str] {
    let r = do(c, [to_bytes("LINDEX"), to_bytes(key),
                   to_bytes(to_str(i))], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind != REPLY_BULK {
        return err("LINDEX: expected a bulk reply");
    }
    return ok(reply.bulk);
}

// LREM: removes count occurrences of val, returns how many went.
pub fn lrem(c: Conn, key: str, count: int, val: bytes,
            deadline: until) -> result[int, str] {
    let r = do(c, [to_bytes("LREM"), to_bytes(key),
                   to_bytes(to_str(count)), val], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "LREM");
}

// ---- sets ------------------------------------------------------------

// SADD: how many members were newly added.
pub fn sadd(c: Conn, key: str, members: [bytes],
            deadline: until) -> result[int, str] {
    return push_int_cmd(c, "SADD", key, members, deadline);
}

pub fn smembers(c: Conn, key: str,
                deadline: until) -> result[[bytes], str] {
    let r = cmd2(c, "SMEMBERS", to_bytes(key), deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    guard let items = as_array(reply, "SMEMBERS") else let e = err_of(as_array(reply, "SMEMBERS")) {
        return err(e);
    }
    let out: [bytes] = [];
    for it in items {
        if it.kind != REPLY_BULK {
            return err("SMEMBERS: expected bulk elements");
        }
        guard let b = it.bulk else {
            return err("SMEMBERS: nil element");
        }
        push(out, b);
    }
    return ok(out);
}

// SREM: how many members were removed.
pub fn srem(c: Conn, key: str, members: [bytes],
            deadline: until) -> result[int, str] {
    return push_int_cmd(c, "SREM", key, members, deadline);
}

pub fn scard(c: Conn, key: str, deadline: until) -> result[int, str] {
    let r = cmd2(c, "SCARD", to_bytes(key), deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "SCARD");
}

pub fn sismember(c: Conn, key: str, member: bytes,
                 deadline: until) -> result[bool, str] {
    let r = do(c, [to_bytes("SISMEMBER"), to_bytes(key), member],
               deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int_bool(reply, "SISMEMBER");
}

// SPOP: a removed member, or none when the set is absent or drained.
pub fn spop(c: Conn, key: str, deadline: until) -> result[opt[bytes], str] {
    let r = cmd2(c, "SPOP", to_bytes(key), deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind != REPLY_BULK {
        return err("SPOP: expected a bulk reply");
    }
    return ok(reply.bulk);
}

// ---- sorted sets -----------------------------------------------------

pub gc struct ZMember {
    member: bytes,
    score: float,
}

// ZADD: how many members were newly added.
pub fn zadd(c: Conn, key: str, members: map[str]float,
            deadline: until) -> result[int, str] {
    let args: [bytes] = [to_bytes("ZADD"), to_bytes(key)];
    for m, s in members {
        push(args, to_bytes(strings.from_float(s)));
        push(args, to_bytes(m));
    }
    let r = do(c, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "ZADD");
}

fn bulk_float(r: Reply, what: str) -> result[float, str] {
    if r.kind != REPLY_BULK {
        return err(what + ": expected a bulk reply");
    }
    guard let b = r.bulk else {
        return err(what + ": unexpected nil");
    }
    let fr = to_float(to_str(b));
    guard let f = fr else {
        return err(what + ": bad score");
    }
    return ok(f);
}

// ZRANGE/ZREVRANGE without scores.
pub fn zrange(c: Conn, key: str, start: int, stop: int,
              deadline: until) -> result[[bytes], str] {
    let r = do(c, [to_bytes("ZRANGE"), to_bytes(key),
                   to_bytes(to_str(start)), to_bytes(to_str(stop))],
               deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    guard let items = as_array(reply, "ZRANGE") else let e = err_of(as_array(reply, "ZRANGE")) {
        return err(e);
    }
    let out: [bytes] = [];
    for it in items {
        if it.kind != REPLY_BULK {
            return err("ZRANGE: expected bulk elements");
        }
        guard let b = it.bulk else {
            return err("ZRANGE: nil element");
        }
        push(out, b);
    }
    return ok(out);
}

// ZRANGE WITHSCORES: member/score pairs in range order.
pub fn zrange_scores(c: Conn, key: str, start: int, stop: int,
                     deadline: until) -> result[[ZMember], str] {
    let r = do(c, [to_bytes("ZRANGE"), to_bytes(key),
                   to_bytes(to_str(start)), to_bytes(to_str(stop)),
                   to_bytes("WITHSCORES")], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    guard let items = as_array(reply, "ZRANGE") else let e = err_of(as_array(reply, "ZRANGE")) {
        return err(e);
    }
    if len(items) % 2 != 0 {
        return err("ZRANGE: odd element count");
    }
    let out: [ZMember] = [];
    let i = 0;
    while i < len(items) {
        if items[i].kind != REPLY_BULK || items[i + 1].kind != REPLY_BULK {
            return err("ZRANGE: expected bulk elements");
        }
        guard let m = items[i].bulk else {
            return err("ZRANGE: nil member");
        }
        let fr = bulk_float(items[i + 1], "ZRANGE");
        guard let f = fr else let e = err_of(fr) {
            return err(e);
        }
        push(out, ZMember { member: m, score: f });
        i = i + 2;
    }
    return ok(out);
}

// ZRANK: the rank, or none when key or member is absent.
pub fn zrank(c: Conn, key: str, member: bytes,
             deadline: until) -> result[opt[int], str] {
    let r = do(c, [to_bytes("ZRANK"), to_bytes(key), member], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind == REPLY_BULK {
        return ok(none);
    }
    if reply.kind != REPLY_INT {
        return err("ZRANK: expected an integer reply");
    }
    return ok(some(reply.num));
}

// ZSCORE: the score, or none when key or member is absent.
pub fn zscore(c: Conn, key: str, member: bytes,
              deadline: until) -> result[opt[float], str] {
    let r = do(c, [to_bytes("ZSCORE"), to_bytes(key), member], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind == REPLY_BULK {
        guard let b = reply.bulk else {
            return ok(none);
        }
        let fr = to_float(to_str(b));
        guard let f = fr else {
            return err("ZSCORE: bad score");
        }
        return ok(some(f));
    }
    return err("ZSCORE: expected a bulk reply");
}

// ZREM: how many members were removed.
pub fn zrem(c: Conn, key: str, members: [bytes],
            deadline: until) -> result[int, str] {
    return push_int_cmd(c, "ZREM", key, members, deadline);
}

pub fn zcard(c: Conn, key: str, deadline: until) -> result[int, str] {
    let r = cmd2(c, "ZCARD", to_bytes(key), deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "ZCARD");
}

pub fn zincr_by(c: Conn, key: str, n: float, member: bytes,
                deadline: until) -> result[float, str] {
    let r = do(c, [to_bytes("ZINCRBY"), to_bytes(key),
                   to_bytes(strings.from_float(n)), member], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return bulk_float(reply, "ZINCRBY");
}

// ---- keys ------------------------------------------------------------

// TYPE: the key's type name ("none" when absent).
pub fn key_type(c: Conn, key: str, deadline: until) -> result[str, str] {
    let r = cmd2(c, "TYPE", to_bytes(key), deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_simple(reply, "TYPE");
}

// RENAME: true on +OK. RENAMENX: true only when newkey was absent.
pub fn rename(c: Conn, key: str, newkey: str,
              deadline: until) -> result[bool, str] {
    let r = do(c, [to_bytes("RENAME"), to_bytes(key), to_bytes(newkey)],
               deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind != REPLY_SIMPLE {
        return err("RENAME: expected a status reply");
    }
    return ok(true);
}

pub fn rename_nx(c: Conn, key: str, newkey: str,
                 deadline: until) -> result[bool, str] {
    let r = do(c, [to_bytes("RENAMENX"), to_bytes(key),
                   to_bytes(newkey)], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int_bool(reply, "RENAMENX");
}

pub gc struct ScanOut {
    cursor: int,
    keys: [str],
}

// SCAN: one cursor step. Thread cursor back in until it returns 0;
// match and count are server hints, both optional. KEYS is
// deliberately absent: it blocks the server for the whole keyspace.
pub fn scan(c: Conn, cursor: int, match: opt[str], count: opt[int],
            deadline: until) -> result[ScanOut, str] {
    let args: [bytes] = [to_bytes("SCAN"), to_bytes(to_str(cursor))];
    guard let m = match else {
        return scan_count(c, args, count, deadline);
    }
    push(args, to_bytes("MATCH"));
    push(args, to_bytes(m));
    return scan_count(c, args, count, deadline);
}

fn scan_count(c: Conn, args: [bytes], count: opt[int],
              deadline: until) -> result[ScanOut, str] {
    guard let n = count else {
        return scan_run(c, args, deadline);
    }
    push(args, to_bytes("COUNT"));
    push(args, to_bytes(to_str(n)));
    return scan_run(c, args, deadline);
}

fn scan_run(c: Conn, args: [bytes],
            deadline: until) -> result[ScanOut, str] {
    let r = do(c, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    guard let items = as_array(reply, "SCAN") else let e = err_of(as_array(reply, "SCAN")) {
        return err(e);
    }
    if len(items) != 2 {
        return err("SCAN: expected two elements");
    }
    if items[0].kind != REPLY_BULK {
        return err("SCAN: bad cursor");
    }
    guard let cb = items[0].bulk else {
        return err("SCAN: nil cursor");
    }
    let cr = to_int(to_str(cb));
    guard let cursor = cr else {
        return err("SCAN: bad cursor");
    }
    if items[1].kind != REPLY_ARRAY || items[1].is_nil {
        return err("SCAN: bad key list");
    }
    let keys: [str] = [];
    for it in items[1].items {
        if it.kind != REPLY_BULK {
            return err("SCAN: expected bulk keys");
        }
        guard let b = it.bulk else {
            return err("SCAN: nil key");
        }
        push(keys, to_str(b));
    }
    return ok(ScanOut { cursor: cursor, keys: keys });
}

// ---- pool ------------------------------------------------------------
// A fixed number of connections shared by every task. Checking one
// out is exclusive until release, exactly like holding a Conn; the
// pool only owns the idle ones. Prefer pool_do, which cannot forget
// to release; acquire is for call sequences that must share one
// connection.

pub gc struct Pool {
    cfg: Config,
    // Connections open at once, idle and checked out together. A task
    // that needs one when all are out waits for a release.
    max_open: int,
    idle: [Conn],
    open: int,
    lock: mutex,
    closed: bool,
}

// Parses the url; connects nothing until the first acquire.
pub fn new_pool(url: str, max_open: int) -> result[Pool, str] {
    let cr = parse_url(url);
    guard let cfg = cr else let e = err_of(cr) {
        return err(e);
    }
    return new_pool_config(cfg, max_open);
}

// Same, from a Config built by hand (pool_size is ignored: max_open
// says it here, once, where the pool is made).
pub fn new_pool_config(cfg: Config, max_open: int) -> result[Pool, str] {
    if max_open < 1 {
        return err("max_open must be at least 1");
    }
    let idle: [Conn] = [];
    return ok(Pool { cfg: cfg, max_open: max_open, idle: idle, open: 0,
                     lock: make_mutex(), closed: false });
}

fn close_locked(c: Conn) {
    if !c.closed {
        c.closed = true;
        tr_close(c);
    }
}

// A connection for the caller's exclusive use, until release().
pub fn acquire(p: Pool, deadline: until) -> result[Conn, str] {
    while true {
        mutex_lock(p.lock);
        if p.closed {
            mutex_unlock(p.lock);
            return err("pool is closed");
        }
        while len(p.idle) > 0 {
            let c = p.idle[len(p.idle) - 1];
            p.idle = p.idle[..len(p.idle) - 1];
            // Probed before reuse: the server closes idle sessions
            // on timers of its own, and a command written onto a
            // closed connection fails in a way that cannot be told
            // from the command itself failing. Leftover bytes mean a
            // previous exchange desynced: never reuse that either.
            let alive = net.idle_alive(c.fd);
            if c.ssl != nullptr {
                alive = net.tls_idle_alive(c.ssl);
            }
            if !usable(c) || !alive || len(c.buf) > c.pos {
                p.open = p.open - 1;
                close_locked(c);
                continue;
            }
            c.in_pool = true;
            mutex_unlock(p.lock);
            return ok(c);
        }
        if p.open < p.max_open {
            p.open = p.open + 1;
            mutex_unlock(p.lock);
            let cr = connect_config(p.cfg, deadline);
            guard let c = cr else let e = err_of(cr) {
                mutex_lock(p.lock);
                p.open = p.open - 1;
                mutex_unlock(p.lock);
                return err(e);
            }
            c.in_pool = true;
            return ok(c);
        }
        mutex_unlock(p.lock);
        if until_hit(deadline) {
            return err("pool: timeout waiting for a connection");
        }
        time.sleep(2000000);
    }
}

// Returns a connection to the pool. One that is broken, closed, or
// inside MULTI is closed instead: handing those to the next caller
// would fail its first command, or run it inside someone else's
// uncommitted transaction.
pub fn release(p: Pool, c: Conn) {
    if !c.in_pool {
        panic("redis.release: connection released twice");
    }
    let reusable = usable(c) && c.mode == 0;
    mutex_lock(p.lock);
    c.in_pool = false;
    if p.closed || !reusable {
        p.open = p.open - 1;
        mutex_unlock(p.lock);
        close_locked(c);
        return;
    }
    push(p.idle, c);
    mutex_unlock(p.lock);
}

// One command on a pooled connection: acquire, run, release. The
// connection goes back even when the command fails.
pub fn pool_do(p: Pool, args: [bytes],
               deadline: until) -> result[Reply, str] {
    let ar = acquire(p, deadline);
    guard let c = ar else let e = err_of(ar) {
        return err(e);
    }
    let r = do(c, args, deadline);
    release(p, c);
    return r;
}

// Closes every idle connection. Connections checked out are closed
// as they are released; acquire fails from now on.
// Closes every idle connection. Connections checked out are closed
// as they are released; acquire fails from now on.
pub fn pool_close(p: Pool) {
    mutex_lock(p.lock);
    p.closed = true;
    for c in p.idle {
        close_locked(c);
    }
    let empty: [Conn] = [];
    p.idle = empty;
    mutex_unlock(p.lock);
}

// ---- cluster ---------------------------------------------------------
// Routing over many primaries by hash slot. Each known node address
// ("host:port") owns a small Pool; a mu-guarded map says which slots
// live where. A MOVED reply refreshes one slot and retries; an ASK
// reply makes one directed hop (ASKING first) without touching the
// map. Anything else -- CROSSSLOT, CLUSTERDOWN, TRYAGAIN -- is the
// caller's to read, exactly as the server wrote it.
//
// Multi-key commands must fit one slot: the cluster wrappers check
// every key up front and refuse CROSSSLOT locally, before any byte
// is sent. Replicas are not read: primaries only in this phase.

let MAX_REDIRECTS = 5;

gc struct Addr {
    host: str,
    port: int,
}

fn split_addr(addr: str) -> result[Addr, str] {
    let host = addr;
    let port = 6379;
    if strings.has_prefix(host, "[") {
        let close = strings.find(host, "]");
        if close < 0 {
            return err("bad address");
        }
        let after = strings.slice(host, close + 1, len(host));
        host = strings.slice(host, 1, close);
        if len(after) > 0 {
            if !strings.has_prefix(after, ":") {
                return err("bad address");
            }
            let pr = to_int(strings.slice(after, 1, len(after)));
            guard let p = pr else {
                return err("bad port in address");
            }
            port = p;
        }
    } else {
        let colon = strings.rfind(host, ":");
        if colon < 0 {
            return err("address must be host:port");
        }
        let pr = to_int(strings.slice(host, colon + 1, len(host)));
        guard let p = pr else {
            return err("bad port in address");
        }
        port = p;
        host = strings.slice(host, 0, colon);
    }
    if len(host) == 0 || port <= 0 || port > 65535 {
        return err("bad address");
    }
    return ok(Addr { host: host, port: port });
}

fn node_config(base: Config, host: str, port: int) -> Config {
    return Config { host: host, port: port, username: base.username,
                    password: base.password, db: 0, sslmode: base.sslmode,
                    ca_path: base.ca_path, tls_ctx: base.tls_ctx,
                    pool_size: base.pool_size,
                    connect_timeout: base.connect_timeout,
                    io_timeout: base.io_timeout };
}

pub gc struct Cluster {
    cfg: Config,
    mu: mutex,
    // Slot -> "host:port". Only assigned slots are present; absent
    // means unknown (refresh and retry).
    slots: map[int]str,
    // Node address -> its pool.
    pools: map[str]Pool,
    // Bootstrap seeds, kept for refresh when no pool exists yet.
    seeds: [str],
    closed: bool,
}

fn cluster_pool_locked(cl: Cluster, addr: str) -> result[Pool, str] {
    if has(cl.pools, addr) {
        return ok(cl.pools[addr]);
    }
    // The caller holds cl.mu; pools serialize themselves.
    let ar = split_addr(addr);
    guard let a = ar else let e = err_of(ar) {
        return err(e);
    }
    let qr = new_pool_config(node_config(cl.cfg, a.host, a.port),
                             cl.cfg.pool_size);
    guard let pool = qr else let e = err_of(qr) {
        return err(e);
    }
    cl.pools[addr] = pool;
    return ok(pool);
}

// Learn the slot map from one node. Returns "" or the error.
fn bootstrap_from(cl: Cluster, addr: str, deadline: until) -> str {
    let ar = split_addr(addr);
    guard let a = ar else let e = err_of(ar) {
        return e;
    }
    let cr = connect_config(node_config(cl.cfg, a.host, a.port),
                            deadline);
    guard let c = cr else let e = err_of(cr) {
        return e;
    }
    let sr = do(c, [to_bytes("CLUSTER"), to_bytes("SLOTS")], deadline);
    close(c);
    guard let reply = sr else let e = err_of(sr) {
        return e;
    }
    if reply.kind != REPLY_ARRAY || reply.is_nil {
        return "CLUSTER SLOTS: expected an array";
    }
    let count = 0;
    for entry in reply.items {
        if entry.kind != REPLY_ARRAY || entry.is_nil ||
           len(entry.items) < 3 {
            return "CLUSTER SLOTS: bad entry";
        }
        if entry.items[0].kind != REPLY_INT ||
           entry.items[1].kind != REPLY_INT {
            return "CLUSTER SLOTS: bad range";
        }
        let start = entry.items[0].num;
        let end = entry.items[1].num;
        if start < 0 || end > 16383 || start > end {
            return "CLUSTER SLOTS: range out of bounds";
        }
        let master = entry.items[2];
        if master.kind != REPLY_ARRAY || master.is_nil ||
           len(master.items) < 2 {
            return "CLUSTER SLOTS: bad node";
        }
        if master.items[0].kind != REPLY_BULK ||
           master.items[1].kind != REPLY_INT {
            return "CLUSTER SLOTS: bad endpoint";
        }
        guard let ip = master.items[0].bulk else {
            return "CLUSTER SLOTS: nil endpoint";
        }
        let node = to_str(ip) + ":" + to_str(master.items[1].num);
        let s = start;
        while s <= end {
            cl.slots[s] = node;
            s = s + 1;
        }
        count = count + 1;
    }
    if count == 0 {
        return "CLUSTER SLOTS: no slots assigned";
    }
    return "";
}

// Connect to a cluster: try each seed until one serves CLUSTER
// SLOTS. Only database 0 exists in cluster mode. The deadline
// covers the whole bootstrap.
pub fn new_cluster(cfg: Config, seeds: [str],
                   deadline: until) -> result[Cluster, str] {
    if cfg.db != 0 {
        return err("cluster mode only supports database 0");
    }
    if cfg.pool_size < 1 {
        return err("pool_size must be at least 1");
    }
    if len(seeds) == 0 {
        return err("at least one seed is required");
    }
    let slots: map[int]str = {};
    let pools: map[str]Pool = {};
    let cl = Cluster { cfg: cfg, mu: make_mutex(), slots: slots,
                       pools: pools, seeds: seeds, closed: false };
    let why = "";
    for seed in seeds {
        let e = bootstrap_from(cl, seed, deadline);
        if e == "" {
            return ok(cl);
        }
        why = e;
    }
    return err(why);
}

// Re-learn the whole slot map from a known node (any current pool
// will do; the first one wins) or a bootstrap seed. Manual recovery
// for outages the MOVED path cannot see.
pub fn cluster_refresh(cl: Cluster, deadline: until) -> result[bool, str] {
    mutex_lock(cl.mu);
    if cl.closed {
        mutex_unlock(cl.mu);
        return err("cluster is closed");
    }
    let addrs: [str] = [];
    for addr, pool in cl.pools {
        push(addrs, addr);
    }
    for seed in cl.seeds {
        push(addrs, seed);
    }
    mutex_unlock(cl.mu);
    let why = "no known nodes";
    for addr in addrs {
        let e = bootstrap_from(cl, addr, deadline);
        if e == "" {
            return ok(true);
        }
        why = e;
    }
    return err(why);
}

// "MOVED 12182 127.0.0.1:6381" -> slot 12182 at that address.
// "ASK 5 ..." parses the same; only the caller decides whether the
// map learns it.
fn parse_redirect(text: str) -> result[Addr, str] {
    let parts = strings.split(text, " ");
    if len(parts) != 3 {
        return err("bad redirect");
    }
    let sr = to_int(parts[1]);
    guard let n = sr else {
        return err("bad redirect slot");
    }
    if n < 0 || n > 16383 {
        return err("bad redirect slot");
    }
    let ar = split_addr(parts[2]);
    guard let a = ar else let e = err_of(ar) {
        return err(e);
    }
    return ok(a);
}

fn redirect_addr(text: str) -> str {
    let parts = strings.split(text, " ");
    if len(parts) != 3 {
        return "";
    }
    return parts[2];
}

// Run args against the node owning key, following MOVED (map update
// plus retry, up to MAX_REDIRECTS) and ASK (one directed ASKING hop,
// returned directly). Every other error returns verbatim.
pub fn cluster_do(cl: Cluster, key: str, args: [bytes],
                  deadline: until) -> result[Reply, str] {
    let tries = 0;
    while tries < 1 + MAX_REDIRECTS {
        tries = tries + 1;
        mutex_lock(cl.mu);
        if cl.closed {
            mutex_unlock(cl.mu);
            return err("cluster is closed");
        }
        let s = slot(key);
        if !has(cl.slots, s) {
            mutex_unlock(cl.mu);
            let fr = cluster_refresh(cl, deadline);
            guard let okv = fr else let e = err_of(fr) {
                return err(e);
            }
            continue;
        }
        let addr = cl.slots[s];
        let pr = cluster_pool_locked(cl, addr);
        mutex_unlock(cl.mu);
        guard let pool = pr else let e = err_of(pr) {
            return err(e);
        }
        let ar = acquire(pool, deadline);
        guard let c = ar else let e = err_of(ar) {
            return err(e);
        }
        let r = do(c, args, deadline);
        release(pool, c);
        guard let reply = r else let e = err_of(r) {
            if strings.has_prefix(e, "MOVED ") {
                let mr = parse_redirect(e);
                guard let a = mr else {
                    return err(e);
                }
                mutex_lock(cl.mu);
                cl.slots[s] = a.host + ":" + to_str(a.port);
                mutex_unlock(cl.mu);
                continue;
            }
            if strings.has_prefix(e, "ASK ") {
                let dst = redirect_addr(e);
                if dst == "" {
                    return err(e);
                }
                return cluster_ask(cl, dst, args, deadline);
            }
            return err(e);
        }
        return ok(reply);
    }
    return err("cluster: too many redirects");
}

// One ASK hop: a fresh connection, ASKING first, then the command.
// The map learns nothing -- the slot is only visiting.
fn cluster_ask(cl: Cluster, dst: str, args: [bytes],
               deadline: until) -> result[Reply, str] {
    let ar = split_addr(dst);
    guard let a = ar else let e = err_of(ar) {
        return err(e);
    }
    let cr = connect_config(node_config(cl.cfg, a.host, a.port),
                            deadline);
    guard let c = cr else let e = err_of(cr) {
        return err(e);
    }
    mutex_lock(c.lock);
    let r = exchange(c, [to_bytes("ASKING")], deadline);
    guard let reply = r else let e = err_of(r) {
        mutex_unlock(c.lock);
        close(c);
        return err(e);
    }
    if reply.kind != REPLY_SIMPLE {
        mutex_unlock(c.lock);
        close(c);
        return err("ASKING: expected a status reply");
    }
    let q = exchange(c, args, deadline);
    mutex_unlock(c.lock);
    close(c);
    guard let final = q else let e = err_of(q) {
        return err(e);
    }
    return ok(final);
}

pub fn cluster_close(cl: Cluster) {
    mutex_lock(cl.mu);
    cl.closed = true;
    for addr, pool in cl.pools {
        pool_close(pool);
    }
    mutex_unlock(cl.mu);
}

// ---- cluster commands ------------------------------------------------
// One thin wrapper per single-key command, routed by that key. Shapes
// and errors match the standalone twins exactly; only the routing
// differs. Multi-key commands check every key first and refuse
// CROSSSLOT locally, with the server's own text.

fn check_same_slot(keys: [str]) -> result[int, str] {
    if len(keys) == 0 {
        return err("at least one key is required");
    }
    let s = slot(keys[0]);
    for k in keys {
        if slot(k) != s {
            return err("CROSSSLOT Keys in request don't hash to the same slot");
        }
    }
    return ok(s);
}

pub fn cping(cl: Cluster, deadline: until) -> result[str, str] {
    let r = cluster_do(cl, "", [to_bytes("PING")], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_simple(reply, "PING");
}

pub fn cecho(cl: Cluster, v: bytes, deadline: until) -> result[bytes, str] {
    let r = cluster_do(cl, "", [to_bytes("ECHO"), v], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_bulk(reply, "ECHO");
}

pub fn cget(cl: Cluster, key: str, deadline: until) -> result[opt[bytes], str] {
    let r = cluster_do(cl, key, [to_bytes("GET"), to_bytes(key)],
                       deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind != REPLY_BULK {
        return err("GET: expected a bulk reply");
    }
    return ok(reply.bulk);
}

pub fn cset(cl: Cluster, key: str, val: bytes,
            deadline: until) -> result[bool, str] {
    let r = cluster_do(cl, key, [to_bytes("SET"), to_bytes(key), val],
                       deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind != REPLY_SIMPLE {
        return err("SET: expected a status reply");
    }
    return ok(true);
}

pub fn cset_ex(cl: Cluster, key: str, seconds: int, val: bytes,
               deadline: until) -> result[bool, str] {
    let r = cluster_do(cl, key, [to_bytes("SET"), to_bytes(key), val,
                                 to_bytes("EX"),
                                 to_bytes(to_str(seconds))], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind != REPLY_SIMPLE {
        return err("SET: expected a status reply");
    }
    return ok(true);
}

pub fn cset_nx(cl: Cluster, key: str, val: bytes,
               deadline: until) -> result[bool, str] {
    let r = cluster_do(cl, key, [to_bytes("SETNX"), to_bytes(key), val],
                       deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int_bool(reply, "SETNX");
}

pub fn cdel_keys(cl: Cluster, keys: [str],
                 deadline: until) -> result[int, str] {
    guard let s = check_same_slot(keys) else let e = err_of(check_same_slot(keys)) {
        return err(e);
    }
    let args: [bytes] = [to_bytes("DEL")];
    for k in keys {
        push(args, to_bytes(k));
    }
    let r = cluster_do(cl, keys[0], args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "DEL");
}

pub fn cexists(cl: Cluster, keys: [str],
               deadline: until) -> result[int, str] {
    guard let s = check_same_slot(keys) else let e = err_of(check_same_slot(keys)) {
        return err(e);
    }
    let args: [bytes] = [to_bytes("EXISTS")];
    for k in keys {
        push(args, to_bytes(k));
    }
    let r = cluster_do(cl, keys[0], args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "EXISTS");
}

pub fn cexpire(cl: Cluster, key: str, seconds: int,
               deadline: until) -> result[bool, str] {
    let r = cluster_do(cl, key, [to_bytes("EXPIRE"), to_bytes(key),
                                 to_bytes(to_str(seconds))], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int_bool(reply, "EXPIRE");
}

pub fn cpexpire(cl: Cluster, key: str, ms: int,
                deadline: until) -> result[bool, str] {
    let r = cluster_do(cl, key, [to_bytes("PEXPIRE"), to_bytes(key),
                                 to_bytes(to_str(ms))], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int_bool(reply, "PEXPIRE");
}

pub fn cttl(cl: Cluster, key: str, deadline: until) -> result[int, str] {
    let r = cluster_do(cl, key, [to_bytes("TTL"), to_bytes(key)],
                       deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "TTL");
}

pub fn cpttl(cl: Cluster, key: str, deadline: until) -> result[int, str] {
    let r = cluster_do(cl, key, [to_bytes("PTTL"), to_bytes(key)],
                       deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "PTTL");
}

pub fn cpersist(cl: Cluster, key: str,
                deadline: until) -> result[bool, str] {
    let r = cluster_do(cl, key, [to_bytes("PERSIST"), to_bytes(key)],
                       deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int_bool(reply, "PERSIST");
}

pub fn cincr(cl: Cluster, key: str, deadline: until) -> result[int, str] {
    let r = cluster_do(cl, key, [to_bytes("INCR"), to_bytes(key)],
                       deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "INCR");
}

pub fn cdecr(cl: Cluster, key: str, deadline: until) -> result[int, str] {
    let r = cluster_do(cl, key, [to_bytes("DECR"), to_bytes(key)],
                       deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "DECR");
}

pub fn cincr_by(cl: Cluster, key: str, n: int,
                deadline: until) -> result[int, str] {
    let r = cluster_do(cl, key, [to_bytes("INCRBY"), to_bytes(key),
                                 to_bytes(to_str(n))], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "INCRBY");
}

pub fn cdecr_by(cl: Cluster, key: str, n: int,
                deadline: until) -> result[int, str] {
    let r = cluster_do(cl, key, [to_bytes("DECRBY"), to_bytes(key),
                                 to_bytes(to_str(n))], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "DECRBY");
}

pub fn cappend(cl: Cluster, key: str, val: bytes,
               deadline: until) -> result[int, str] {
    let r = cluster_do(cl, key, [to_bytes("APPEND"), to_bytes(key), val],
                       deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "APPEND");
}

pub fn cstrlen(cl: Cluster, key: str,
               deadline: until) -> result[int, str] {
    let r = cluster_do(cl, key, [to_bytes("STRLEN"), to_bytes(key)],
                       deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "STRLEN");
}

pub fn cmget(cl: Cluster, keys: [str],
             deadline: until) -> result[[opt[bytes]], str] {
    guard let s = check_same_slot(keys) else let e = err_of(check_same_slot(keys)) {
        return err(e);
    }
    let args: [bytes] = [to_bytes("MGET")];
    for k in keys {
        push(args, to_bytes(k));
    }
    let r = cluster_do(cl, keys[0], args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    guard let items = as_array(reply, "MGET") else let e = err_of(as_array(reply, "MGET")) {
        return err(e);
    }
    let out: [opt[bytes]] = [];
    for it in items {
        if it.kind != REPLY_BULK {
            return err("MGET: expected bulk elements");
        }
        push(out, it.bulk);
    }
    return ok(out);
}

pub fn cmset(cl: Cluster, kv: map[str]bytes,
             deadline: until) -> result[bool, str] {
    let args: [bytes] = [to_bytes("MSET")];
    let first = "";
    for k, v in kv {
        if first == "" {
            first = k;
        }
        if slot(k) != slot(first) {
            return err("CROSSSLOT Keys in request don't hash to the same slot");
        }
        push(args, to_bytes(k));
        push(args, v);
    }
    if first == "" {
        return err("at least one key is required");
    }
    let r = cluster_do(cl, first, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind != REPLY_SIMPLE {
        return err("MSET: expected a status reply");
    }
    return ok(true);
}

pub fn chset(cl: Cluster, key: str, field: str, val: bytes,
             deadline: until) -> result[int, str] {
    let r = cluster_do(cl, key, [to_bytes("HSET"), to_bytes(key),
                                 to_bytes(field), val], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "HSET");
}

pub fn chget(cl: Cluster, key: str, field: str,
             deadline: until) -> result[opt[bytes], str] {
    let r = cluster_do(cl, key, [to_bytes("HGET"), to_bytes(key),
                                 to_bytes(field)], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind != REPLY_BULK {
        return err("HGET: expected a bulk reply");
    }
    return ok(reply.bulk);
}

pub fn chdel(cl: Cluster, key: str, fields: [str],
             deadline: until) -> result[int, str] {
    let args: [bytes] = [to_bytes("HDEL"), to_bytes(key)];
    for f in fields {
        push(args, to_bytes(f));
    }
    let r = cluster_do(cl, key, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "HDEL");
}

pub fn chexists(cl: Cluster, key: str, field: str,
                deadline: until) -> result[bool, str] {
    let r = cluster_do(cl, key, [to_bytes("HEXISTS"), to_bytes(key),
                                 to_bytes(field)], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int_bool(reply, "HEXISTS");
}

pub fn chlen(cl: Cluster, key: str, deadline: until) -> result[int, str] {
    let r = cluster_do(cl, key, [to_bytes("HLEN"), to_bytes(key)],
                       deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "HLEN");
}

pub fn chincr_by(cl: Cluster, key: str, field: str, n: int,
                 deadline: until) -> result[int, str] {
    let r = cluster_do(cl, key, [to_bytes("HINCRBY"), to_bytes(key),
                                 to_bytes(field),
                                 to_bytes(to_str(n))], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "HINCRBY");
}

pub fn clpush(cl: Cluster, key: str, vals: [bytes],
              deadline: until) -> result[int, str] {
    let args: [bytes] = [to_bytes("LPUSH"), to_bytes(key)];
    for v in vals {
        push(args, v);
    }
    let r = cluster_do(cl, key, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "LPUSH");
}

pub fn crpush(cl: Cluster, key: str, vals: [bytes],
              deadline: until) -> result[int, str] {
    let args: [bytes] = [to_bytes("RPUSH"), to_bytes(key)];
    for v in vals {
        push(args, v);
    }
    let r = cluster_do(cl, key, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "RPUSH");
}

pub fn clpop(cl: Cluster, key: str,
             deadline: until) -> result[opt[bytes], str] {
    let r = cluster_do(cl, key, [to_bytes("LPOP"), to_bytes(key)],
                       deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind != REPLY_BULK {
        return err("LPOP: expected a bulk reply");
    }
    return ok(reply.bulk);
}

pub fn crpop(cl: Cluster, key: str,
             deadline: until) -> result[opt[bytes], str] {
    let r = cluster_do(cl, key, [to_bytes("RPOP"), to_bytes(key)],
                       deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind != REPLY_BULK {
        return err("RPOP: expected a bulk reply");
    }
    return ok(reply.bulk);
}

pub fn cllen(cl: Cluster, key: str, deadline: until) -> result[int, str] {
    let r = cluster_do(cl, key, [to_bytes("LLEN"), to_bytes(key)],
                       deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "LLEN");
}

pub fn csadd(cl: Cluster, key: str, members: [bytes],
             deadline: until) -> result[int, str] {
    let args: [bytes] = [to_bytes("SADD"), to_bytes(key)];
    for v in members {
        push(args, v);
    }
    let r = cluster_do(cl, key, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "SADD");
}

pub fn csrem(cl: Cluster, key: str, members: [bytes],
             deadline: until) -> result[int, str] {
    let args: [bytes] = [to_bytes("SREM"), to_bytes(key)];
    for v in members {
        push(args, v);
    }
    let r = cluster_do(cl, key, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "SREM");
}

pub fn cscard(cl: Cluster, key: str, deadline: until) -> result[int, str] {
    let r = cluster_do(cl, key, [to_bytes("SCARD"), to_bytes(key)],
                       deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "SCARD");
}

pub fn csismember(cl: Cluster, key: str, member: bytes,
                  deadline: until) -> result[bool, str] {
    let r = cluster_do(cl, key, [to_bytes("SISMEMBER"), to_bytes(key),
                                 member], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int_bool(reply, "SISMEMBER");
}

pub fn czadd(cl: Cluster, key: str, members: map[str]float,
             deadline: until) -> result[int, str] {
    let args: [bytes] = [to_bytes("ZADD"), to_bytes(key)];
    for m, s in members {
        push(args, to_bytes(strings.from_float(s)));
        push(args, to_bytes(m));
    }
    let r = cluster_do(cl, key, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "ZADD");
}

pub fn czrem(cl: Cluster, key: str, members: [bytes],
             deadline: until) -> result[int, str] {
    let args: [bytes] = [to_bytes("ZREM"), to_bytes(key)];
    for v in members {
        push(args, v);
    }
    let r = cluster_do(cl, key, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "ZREM");
}

pub fn czcard(cl: Cluster, key: str, deadline: until) -> result[int, str] {
    let r = cluster_do(cl, key, [to_bytes("ZCARD"), to_bytes(key)],
                       deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "ZCARD");
}

pub fn czscore(cl: Cluster, key: str, member: bytes,
               deadline: until) -> result[opt[float], str] {
    let r = cluster_do(cl, key, [to_bytes("ZSCORE"), to_bytes(key),
                                 member], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind == REPLY_BULK {
        guard let b = reply.bulk else {
            return ok(none);
        }
        let fr = to_float(to_str(b));
        guard let f = fr else {
            return err("ZSCORE: bad score");
        }
        return ok(some(f));
    }
    return err("ZSCORE: expected a bulk reply");
}

pub fn ckey_type(cl: Cluster, key: str,
                 deadline: until) -> result[str, str] {
    let r = cluster_do(cl, key, [to_bytes("TYPE"), to_bytes(key)],
                       deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_simple(reply, "TYPE");
}

pub fn crename(cl: Cluster, key: str, newkey: str,
               deadline: until) -> result[bool, str] {
    let keys = [key, newkey];
    guard let s = check_same_slot(keys) else let e = err_of(check_same_slot(keys)) {
        return err(e);
    }
    let r = cluster_do(cl, key, [to_bytes("RENAME"), to_bytes(key),
                                 to_bytes(newkey)], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind != REPLY_SIMPLE {
        return err("RENAME: expected a status reply");
    }
    return ok(true);
}

// SCAN steps one node only (slot 0's owner): cluster-wide iteration
// fans out per node with cluster_refresh's map in hand.
pub fn cscan(cl: Cluster, cursor: int, match: opt[str], count: opt[int],
             deadline: until) -> result[ScanOut, str] {
    let args: [bytes] = [to_bytes("SCAN"), to_bytes(to_str(cursor))];
    guard let m = match else {
        return cscan_count(cl, args, count, deadline);
    }
    push(args, to_bytes("MATCH"));
    push(args, to_bytes(m));
    return cscan_count(cl, args, count, deadline);
}

fn cscan_count(cl: Cluster, args: [bytes], count: opt[int],
               deadline: until) -> result[ScanOut, str] {
    guard let n = count else {
        return cscan_run(cl, args, deadline);
    }
    push(args, to_bytes("COUNT"));
    push(args, to_bytes(to_str(n)));
    return cscan_run(cl, args, deadline);
}

fn cscan_run(cl: Cluster, args: [bytes],
             deadline: until) -> result[ScanOut, str] {
    let r = cluster_do(cl, "", args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    guard let items = as_array(reply, "SCAN") else let e = err_of(as_array(reply, "SCAN")) {
        return err(e);
    }
    if len(items) != 2 {
        return err("SCAN: expected two elements");
    }
    if items[0].kind != REPLY_BULK {
        return err("SCAN: bad cursor");
    }
    guard let cb = items[0].bulk else {
        return err("SCAN: nil cursor");
    }
    let cr = to_int(to_str(cb));
    guard let cursor = cr else {
        return err("SCAN: bad cursor");
    }
    if items[1].kind != REPLY_ARRAY || items[1].is_nil {
        return err("SCAN: bad key list");
    }
    let keys: [str] = [];
    for it in items[1].items {
        if it.kind != REPLY_BULK {
            return err("SCAN: expected bulk keys");
        }
        guard let b = it.bulk else {
            return err("SCAN: nil key");
        }
        push(keys, to_str(b));
    }
    return ok(ScanOut { cursor: cursor, keys: keys });
}

// ---- transactions ----------------------------------------------------
// MULTI/EXEC over one Conn: every queued call must reach the same
// connection, so transactions run on direct Conns, never through the
// pool (release closes a MULTI conn instead of reusing it) and never
// through cluster_do (which may route each call elsewhere). For one
// node of a cluster, connect to its address directly.
//
// While mode is 1, do and every typed command refuse: the server
// answers +QUEUED, which no reply shape could read. queue takes the
// raw +QUEUED reply; exec returns the per-command replies verbatim,
// errors included -- an element may be REPLY_ERROR while its
// neighbours succeeded.

// MULTI: true on +OK. The connection leaves the pool from here
// until EXEC or DISCARD.
pub fn multi(c: Conn, deadline: until) -> result[bool, str] {
    mutex_lock(c.lock);
    if c.mode == 1 {
        mutex_unlock(c.lock);
        return err("already inside MULTI");
    }
    let r = exchange(c, [to_bytes("MULTI")], deadline);
    guard let reply = r else let e = err_of(r) {
        mutex_unlock(c.lock);
        return err(e);
    }
    if reply.kind != REPLY_SIMPLE {
        mutex_unlock(c.lock);
        return err("MULTI: expected a status reply");
    }
    c.mode = 1;
    mutex_unlock(c.lock);
    return ok(true);
}

// Queue one command inside MULTI. Anything but +QUEUED aborts the
// whole transaction server-side; that surfaces here as an err, and a
// later EXEC answers EXECABORT.
pub fn queue(c: Conn, args: [bytes],
             deadline: until) -> result[bool, str] {
    mutex_lock(c.lock);
    if c.mode != 1 {
        mutex_unlock(c.lock);
        return err("queue needs MULTI first");
    }
    let r = exchange(c, args, deadline);
    guard let reply = r else let e = err_of(r) {
        mutex_unlock(c.lock);
        return err(e);
    }
    if reply.kind != REPLY_SIMPLE || reply.text != "QUEUED" {
        mutex_unlock(c.lock);
        return err("queue: expected +QUEUED");
    }
    mutex_unlock(c.lock);
    return ok(true);
}

// EXEC: the queued replies in order, error elements included. A nil
// array means nothing ran (watched keys changed): an err, since no
// caller could use an empty success. Always leaves MULTI, even on
// EXECABORT -- the server does too.
pub fn exec(c: Conn, deadline: until) -> result[[Reply], str] {
    mutex_lock(c.lock);
    if c.mode != 1 {
        mutex_unlock(c.lock);
        return err("exec needs MULTI first");
    }
    let r = exchange(c, [to_bytes("EXEC")], deadline);
    c.mode = 0;
    guard let reply = r else let e = err_of(r) {
        mutex_unlock(c.lock);
        return err(e);
    }
    if reply.kind == REPLY_ERROR {
        mutex_unlock(c.lock);
        return err(reply.text);
    }
    if reply.kind != REPLY_ARRAY || reply.is_nil {
        mutex_unlock(c.lock);
        return err("EXEC aborted: watched keys changed or empty transaction");
    }
    let out = reply.items;
    mutex_unlock(c.lock);
    return ok(out);
}

// DISCARD: true on +OK, back outside MULTI either way the server
// answers.
pub fn discard(c: Conn, deadline: until) -> result[bool, str] {
    mutex_lock(c.lock);
    let r = exchange(c, [to_bytes("DISCARD")], deadline);
    c.mode = 0;
    guard let reply = r else let e = err_of(r) {
        mutex_unlock(c.lock);
        return err(e);
    }
    if reply.kind != REPLY_SIMPLE {
        mutex_unlock(c.lock);
        return err("DISCARD: expected a status reply");
    }
    mutex_unlock(c.lock);
    return ok(true);
}

// WATCH/UNWATCH for optimistic locking: watch, read, MULTI, queue,
// EXEC; a nil EXEC (err here) means someone else wrote first, so
// retry the whole sequence.
pub fn watch(c: Conn, keys: [str],
             deadline: until) -> result[bool, str] {
    let args: [bytes] = [to_bytes("WATCH")];
    for k in keys {
        push(args, to_bytes(k));
    }
    mutex_lock(c.lock);
    if c.mode == 1 {
        mutex_unlock(c.lock);
        return err("WATCH inside MULTI is not allowed");
    }
    let r = exchange(c, args, deadline);
    guard let reply = r else let e = err_of(r) {
        mutex_unlock(c.lock);
        return err(e);
    }
    if reply.kind != REPLY_SIMPLE {
        mutex_unlock(c.lock);
        return err("WATCH: expected a status reply");
    }
    mutex_unlock(c.lock);
    return ok(true);
}

pub fn unwatch(c: Conn, deadline: until) -> result[bool, str] {
    mutex_lock(c.lock);
    let r = exchange(c, [to_bytes("UNWATCH")], deadline);
    guard let reply = r else let e = err_of(r) {
        mutex_unlock(c.lock);
        return err(e);
    }
    if reply.kind != REPLY_SIMPLE {
        mutex_unlock(c.lock);
        return err("UNWATCH: expected a status reply");
    }
    mutex_unlock(c.lock);
    return ok(true);
}

// ---- scripting -------------------------------------------------------

fn script_args(cmd: str, sha_or_src: bytes, keys: [str], args: [bytes]) -> [bytes] {
    let out: [bytes] = [to_bytes(cmd), sha_or_src,
                        to_bytes(to_str(len(keys)))];
    for k in keys {
        push(out, to_bytes(k));
    }
    for a in args {
        push(out, a);
    }
    return out;
}

// EVAL: the script's raw reply, whose shape depends on what it
// returns -- bulk, int, array, or error, decoded verbatim.
pub fn eval(c: Conn, script: str, keys: [str], args: [bytes],
            deadline: until) -> result[Reply, str] {
    return do(c, script_args("EVAL", to_bytes(script), keys, args),
              deadline);
}

// EVALSHA with automatic EVAL fallback: the common path sends only
// 40 hex characters; a server that never saw the script answers
// NOSCRIPT and the call transparently re-sends the source.
pub fn evalsha(c: Conn, script: str, keys: [str], args: [bytes],
               deadline: until) -> result[Reply, str] {
    let sha = encoding.hex_encode(crypto.sha1(to_bytes(script)));
    let r = do(c, script_args("EVALSHA", to_bytes(sha), keys, args),
               deadline);
    guard let reply = r else let e = err_of(r) {
        if strings.contains(e, "NOSCRIPT") {
            return eval(c, script, keys, args, deadline);
        }
        return err(e);
    }
    return ok(reply);
}

// ---- pub/sub ---------------------------------------------------------
// Subscriber mode is a different protocol state: every read is an
// array (message, pmessage, or a subscribe/unsubscribe/pong
// confirm), so a subscriber connection is dedicated -- it runs no
// other commands. The pull model fits that best: sub_next blocks
// with a deadline and the caller decides buffering and fan-out (a
// 4-line pump feeds a chan when push suits better), instead of the
// library hiding a reader task, a timer, and a loss policy. No
// polling, no background wakeups, flow control by construction: an
// app that stops calling stops receiving, and TCP backpressure does
// the rest.
//
// All socket I/O goes under one lock, so one task may pump while
// another (un)subscribes: confirms are consumed by whoever asked,
// anything else lands in pending for the next sub_next.

// A published message. kind is "message" or "pmessage"; pattern is
// set only for the latter (the glob that matched).
pub gc struct Message {
    kind: str,
    channel: str,
    pattern: str,
    payload: bytes,
}

// A live subscription: a dedicated subscriber-mode connection plus
// messages that arrived while someone else held the lock. Never use
// sub.c directly (do, close, anything): concurrent socket readers
// would split the stream mid-reply. Everything here serializes on
// the Sub lock instead.
pub gc struct Sub {
    c: Conn,
    pending: [Message],
    lock: mutex,
}

fn as_message(r: Reply) -> result[opt[Message], str] {
    if r.kind != REPLY_ARRAY || r.is_nil || len(r.items) < 3 {
        return err("not a message");
    }
    if r.items[0].kind != REPLY_BULK {
        return err("not a message");
    }
    guard let tag = r.items[0].bulk else {
        return err("not a message");
    }
    let kind = to_str(tag);
    if kind == "message" {
        if len(r.items) != 3 {
            return err("bad message shape");
        }
        if r.items[1].kind != REPLY_BULK || r.items[2].kind != REPLY_BULK {
            return err("bad message shape");
        }
        guard let ch = r.items[1].bulk else {
            return err("bad message shape");
        }
        guard let pl = r.items[2].bulk else {
            return err("bad message shape");
        }
        return ok(some(Message { kind: kind, channel: to_str(ch),
                                 pattern: "", payload: pl }));
    }
    if kind == "pmessage" {
        if len(r.items) != 4 {
            return err("bad message shape");
        }
        if r.items[1].kind != REPLY_BULK ||
           r.items[2].kind != REPLY_BULK ||
           r.items[3].kind != REPLY_BULK {
            return err("bad message shape");
        }
        guard let pat = r.items[1].bulk else {
            return err("bad message shape");
        }
        guard let ch = r.items[2].bulk else {
            return err("bad message shape");
        }
        guard let pl = r.items[3].bulk else {
            return err("bad message shape");
        }
        return ok(some(Message { kind: kind, channel: to_str(ch),
                                 pattern: to_str(pat), payload: pl }));
    }
    return ok(none);
}

// Read confirms until n subscribe/unsubscribe acks arrive, buffering
// any messages that interleave into pending. Confirms are counted
// positionally: the server answers our command with exactly n of
// them, in order, so anything else on the wire meanwhile is a live
// message. The caller holds sub.lock.
fn sub_confirms(sub: Sub, n: int, deadline: until) -> result[bool, str] {
    let got = 0;
    while got < n {
        let r = read_reply(sub.c, deadline);
        guard let reply = r else let e = err_of(r) {
            return err(e);
        }
        let m = as_message(reply);
        guard let msg = m else let e = err_of(m) {
            return err(e);
        }
        guard let mm = msg else {
            got = got + 1;
            continue;
        }
        push(sub.pending, mm);
    }
    return ok(true);
}

// Subscribe, returning a live Sub. channels and patterns are the
// SUBSCRIBE and PSUBSCRIBE lists; at least one of them is nonempty.
pub fn subscribe(url: str, channels: [str], patterns: [str],
                 deadline: until) -> result[Sub, str] {
    if len(channels) == 0 && len(patterns) == 0 {
        return err("subscribe needs a channel or pattern");
    }
    let cr = connect(url, deadline);
    guard let c = cr else let e = err_of(cr) {
        return err(e);
    }
    let sub = Sub { c: c, pending: [], lock: make_mutex() };
    let ar = sub_add(sub, channels, patterns, deadline);
    guard let okv = ar else let e = err_of(ar) {
        close(c);
        return err(e);
    }
    return ok(sub);
}

// Add subscriptions to a live Sub.
pub fn sub_add(sub: Sub, channels: [str], patterns: [str],
               deadline: until) -> result[bool, str] {
    if len(channels) == 0 && len(patterns) == 0 {
        return err("subscribe needs a channel or pattern");
    }
    mutex_lock(sub.lock);
    if len(channels) > 0 {
        let args: [bytes] = [to_bytes("SUBSCRIBE")];
        for ch in channels {
            push(args, to_bytes(ch));
        }
        let sr = send_all(sub.c, encode(args), deadline);
        guard let sent = sr else let e = err_of(sr) {
            mutex_unlock(sub.lock);
            return err(e);
        }
        let cr = sub_confirms(sub, len(channels), deadline);
        guard let okv = cr else let e = err_of(cr) {
            mutex_unlock(sub.lock);
            return err(e);
        }
    }
    if len(patterns) > 0 {
        let args: [bytes] = [to_bytes("PSUBSCRIBE")];
        for p in patterns {
            push(args, to_bytes(p));
        }
        let sr = send_all(sub.c, encode(args), deadline);
        guard let sent = sr else let e = err_of(sr) {
            mutex_unlock(sub.lock);
            return err(e);
        }
        let cr = sub_confirms(sub, len(patterns), deadline);
        guard let okv = cr else let e = err_of(cr) {
            mutex_unlock(sub.lock);
            return err(e);
        }
    }
    mutex_unlock(sub.lock);
    return ok(true);
}

// Next message, or none when the deadline passes first. Confirms
// and pongs the server interleaves are skipped, never surfaced; a
// malformed reply is an error, since valid RESP has only the shapes
// as_message knows.
pub fn sub_next(sub: Sub, deadline: until) -> result[opt[Message], str] {
    mutex_lock(sub.lock);
    if len(sub.pending) > 0 {
        let m = sub.pending[0];
        sub.pending = sub.pending[1..];
        mutex_unlock(sub.lock);
        return ok(some(m));
    }
    while true {
        let r = read_reply(sub.c, deadline);
        guard let reply = r else let e = err_of(r) {
            mutex_unlock(sub.lock);
            // The reserved timeout string, not a failure: the caller
            // asked how long to wait, and nothing arrived.
            if e == "recv: timeout" {
                let nothing: opt[Message] = none;
                return ok(nothing);
            }
            return err(e);
        }
        let m = as_message(reply);
        guard let msg = m else let e = err_of(m) {
            mutex_unlock(sub.lock);
            return err(e);
        }
        guard let mm = msg else {
            continue;
        }
        mutex_unlock(sub.lock);
        return ok(some(mm));
    }
}

// Remove subscriptions. Fully unsubscribing returns the connection
// to plain unicast mode; close it or subscribe again after.
pub fn sub_remove(sub: Sub, channels: [str], patterns: [str],
                  deadline: until) -> result[bool, str] {
    mutex_lock(sub.lock);
    if len(channels) > 0 {
        let args: [bytes] = [to_bytes("UNSUBSCRIBE")];
        for ch in channels {
            push(args, to_bytes(ch));
        }
        let sr = send_all(sub.c, encode(args), deadline);
        guard let sent = sr else let e = err_of(sr) {
            mutex_unlock(sub.lock);
            return err(e);
        }
        let cr = sub_confirms(sub, len(channels), deadline);
        guard let okv = cr else let e = err_of(cr) {
            mutex_unlock(sub.lock);
            return err(e);
        }
    }
    if len(patterns) > 0 {
        let args: [bytes] = [to_bytes("PUNSUBSCRIBE")];
        for p in patterns {
            push(args, to_bytes(p));
        }
        let sr = send_all(sub.c, encode(args), deadline);
        guard let sent = sr else let e = err_of(sr) {
            mutex_unlock(sub.lock);
            return err(e);
        }
        let cr = sub_confirms(sub, len(patterns), deadline);
        guard let okv = cr else let e = err_of(cr) {
            mutex_unlock(sub.lock);
            return err(e);
        }
    }
    mutex_unlock(sub.lock);
    return ok(true);
}

// Shut a subscription down. A task blocked in sub_next wakes with an
// error from the closed socket.
pub fn sub_close(sub: Sub) {
    close(sub.c);
}

// ---- streams ---------------------------------------------------------
// Append-only logs: XADD/XRANGE/XREAD/XLEN/XTRIM/XDEL. Consumer
// groups (XREADGROUP/XACK/XPENDING/XCLAIM) are a later phase: they
// are a second protocol for the same log, not needed to read and
// write it. Entry IDs are "ms-seq" strings; "*" asks the server.

pub gc struct StreamEntry {
    id: str,
    fields: map[str]bytes,
}

pub gc struct StreamRead {
    key: str,
    entries: [StreamEntry],
}

fn parse_fields(items: [Reply], what: str) -> result[map[str]bytes, str] {
    if len(items) % 2 != 0 {
        return err(what + ": odd field count");
    }
    let out: map[str]bytes = {};
    let i = 0;
    while i < len(items) {
        if items[i].kind != REPLY_BULK || items[i + 1].kind != REPLY_BULK {
            return err(what + ": expected bulk fields");
        }
        guard let f = items[i].bulk else {
            return err(what + ": nil field");
        }
        guard let v = items[i + 1].bulk else {
            return err(what + ": nil value");
        }
        out[to_str(f)] = v;
        i = i + 2;
    }
    return ok(out);
}

fn parse_entry(r: Reply, what: str) -> result[StreamEntry, str] {
    if r.kind != REPLY_ARRAY || r.is_nil || len(r.items) != 2 {
        return err(what + ": bad entry");
    }
    if r.items[0].kind != REPLY_BULK {
        return err(what + ": bad entry id");
    }
    guard let idb = r.items[0].bulk else {
        return err(what + ": nil entry id");
    }
    if r.items[1].kind != REPLY_ARRAY || r.items[1].is_nil {
        return err(what + ": bad entry fields");
    }
    let fr = parse_fields(r.items[1].items, what);
    guard let fields = fr else let e = err_of(fr) {
        return err(e);
    }
    return ok(StreamEntry { id: to_str(idb), fields: fields });
}

// XADD: the new entry's ID.
pub fn xadd(c: Conn, key: str, id: str, fields: map[str]bytes,
            deadline: until) -> result[str, str] {
    let args: [bytes] = [to_bytes("XADD"), to_bytes(key), to_bytes(id)];
    for f, v in fields {
        push(args, to_bytes(f));
        push(args, v);
    }
    let r = do(c, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind != REPLY_BULK {
        return err("XADD: expected a bulk reply");
    }
    guard let b = reply.bulk else {
        return err("XADD: nil id");
    }
    return ok(to_str(b));
}

// XADD with MAXLEN trimming: approx picks ~ (cheap) over exact.
pub fn xadd_maxlen(c: Conn, key: str, maxlen: int, approx: bool, id: str,
                   fields: map[str]bytes,
                   deadline: until) -> result[str, str] {
    let args: [bytes] = [to_bytes("XADD"), to_bytes(key),
                         to_bytes("MAXLEN")];
    if approx {
        push(args, to_bytes("~"));
    }
    push(args, to_bytes(to_str(maxlen)));
    push(args, to_bytes(id));
    for f, v in fields {
        push(args, to_bytes(f));
        push(args, v);
    }
    let r = do(c, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind != REPLY_BULK {
        return err("XADD: expected a bulk reply");
    }
    guard let b = reply.bulk else {
        return err("XADD: nil id");
    }
    return ok(to_str(b));
}

fn xrange_run(c: Conn, rev: bool, key: str, start: str, end: str,
              count: opt[int],
              deadline: until) -> result[[StreamEntry], str] {
    let name = "XRANGE";
    if rev {
        name = "XREVRANGE";
    }
    let args: [bytes] = [to_bytes(name), to_bytes(key), to_bytes(start),
                         to_bytes(end)];
    guard let n = count else {
        return xrange_call(c, args, name, deadline);
    }
    push(args, to_bytes("COUNT"));
    push(args, to_bytes(to_str(n)));
    return xrange_call(c, args, name, deadline);
}

fn xrange_call(c: Conn, args: [bytes], name: str,
               deadline: until) -> result[[StreamEntry], str] {
    let r = do(c, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    guard let items = as_array(reply, name) else let e = err_of(as_array(reply, name)) {
        return err(e);
    }
    let out: [StreamEntry] = [];
    for it in items {
        let er = parse_entry(it, name);
        guard let e = er else let e = err_of(er) {
            return err(e);
        }
        push(out, e);
    }
    return ok(out);
}

// XRANGE/XREVRANGE: entries between two IDs ("-" and "+" are the
// ends), oldest first (XREVRANGE newest first). count caps the
// reply, none for no cap.
pub fn xrange(c: Conn, key: str, start: str, end: str, count: opt[int],
              deadline: until) -> result[[StreamEntry], str] {
    return xrange_run(c, false, key, start, end, count, deadline);
}

pub fn xrevrange(c: Conn, key: str, end: str, start: str, count: opt[int],
                 deadline: until) -> result[[StreamEntry], str] {
    return xrange_run(c, true, key, end, start, count, deadline);
}

pub fn xlen(c: Conn, key: str, deadline: until) -> result[int, str] {
    let r = do(c, [to_bytes("XLEN"), to_bytes(key)], deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "XLEN");
}

// XTRIM MAXLEN: how many entries were removed.
pub fn xtrim(c: Conn, key: str, maxlen: int, approx: bool,
             deadline: until) -> result[int, str] {
    let args: [bytes] = [to_bytes("XTRIM"), to_bytes(key),
                         to_bytes("MAXLEN")];
    if approx {
        push(args, to_bytes("~"));
    }
    push(args, to_bytes(to_str(maxlen)));
    let r = do(c, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "XTRIM");
}

pub fn xdel(c: Conn, key: str, ids: [str],
            deadline: until) -> result[int, str] {
    let args: [bytes] = [to_bytes("XDEL"), to_bytes(key)];
    for id in ids {
        push(args, to_bytes(id));
    }
    let r = do(c, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "XDEL");
}

// XREAD: new entries per key since each id ("$" means "everything
// after now" on first call, then the last seen id after). block_ms
// waits that long for data (none => return at once); a wait that
// finds nothing is ok(none), not an error. count caps per call.
pub fn xread(c: Conn, keys: [str], ids: [str], block_ms: opt[int],
             count: opt[int],
             deadline: until) -> result[opt[[StreamRead]], str] {
    if len(keys) == 0 || len(keys) != len(ids) {
        return err("XREAD needs one id per key");
    }
    let args: [bytes] = [to_bytes("XREAD")];
    guard let n = count else {
        return xread_block(c, args, keys, ids, block_ms, deadline);
    }
    push(args, to_bytes("COUNT"));
    push(args, to_bytes(to_str(n)));
    return xread_block(c, args, keys, ids, block_ms, deadline);
}

fn xread_block(c: Conn, args: [bytes], keys: [str], ids: [str],
               block_ms: opt[int],
               deadline: until) -> result[opt[[StreamRead]], str] {
    guard let ms = block_ms else {
        return xread_run(c, args, keys, ids, deadline);
    }
    push(args, to_bytes("BLOCK"));
    push(args, to_bytes(to_str(ms)));
    return xread_run(c, args, keys, ids, deadline);
}

fn xread_run(c: Conn, args: [bytes], keys: [str], ids: [str],
             deadline: until) -> result[opt[[StreamRead]], str] {
    push(args, to_bytes("STREAMS"));
    for k in keys {
        push(args, to_bytes(k));
    }
    for id in ids {
        push(args, to_bytes(id));
    }
    let r = do(c, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind == REPLY_ARRAY && reply.is_nil {
        let nothing: opt[[StreamRead]] = none;
        return ok(nothing);
    }
    guard let items = as_array(reply, "XREAD") else let e = err_of(as_array(reply, "XREAD")) {
        return err(e);
    }
    let out: [StreamRead] = [];
    for it in items {
        if it.kind != REPLY_ARRAY || it.is_nil || len(it.items) != 2 {
            return err("XREAD: bad key block");
        }
        if it.items[0].kind != REPLY_BULK {
            return err("XREAD: bad key name");
        }
        guard let kb = it.items[0].bulk else {
            return err("XREAD: nil key");
        }
        if it.items[1].kind != REPLY_ARRAY || it.items[1].is_nil {
            return err("XREAD: bad entry list");
        }
        let entries: [StreamEntry] = [];
        for e in it.items[1].items {
            let er = parse_entry(e, "XREAD");
            guard let entry = er else let e = err_of(er) {
                return err(e);
            }
            push(entries, entry);
        }
        push(out, StreamRead { key: to_str(kb), entries: entries });
    }
    return ok(some(out));
}

// ---- cluster streams -------------------------------------------------
// Same shapes as above, routed by key. XREAD across keys requires
// one slot (checked up front, like MGET).

pub fn cxadd(cl: Cluster, key: str, id: str, fields: map[str]bytes,
             deadline: until) -> result[str, str] {
    let args: [bytes] = [to_bytes("XADD"), to_bytes(key), to_bytes(id)];
    for f, v in fields {
        push(args, to_bytes(f));
        push(args, v);
    }
    let r = cluster_do(cl, key, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind != REPLY_BULK {
        return err("XADD: expected a bulk reply");
    }
    guard let b = reply.bulk else {
        return err("XADD: nil id");
    }
    return ok(to_str(b));
}

pub fn cxlen(cl: Cluster, key: str, deadline: until) -> result[int, str] {
    let r = cluster_do(cl, key, [to_bytes("XLEN"), to_bytes(key)],
                       deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return as_int(reply, "XLEN");
}

pub fn cxread(cl: Cluster, keys: [str], ids: [str], block_ms: opt[int],
              count: opt[int],
              deadline: until) -> result[opt[[StreamRead]], str] {
    if len(keys) == 0 || len(keys) != len(ids) {
        return err("XREAD needs one id per key");
    }
    guard let s = check_same_slot(keys) else let e = err_of(check_same_slot(keys)) {
        return err(e);
    }
    let args: [bytes] = [to_bytes("XREAD")];
    guard let n = count else {
        return cxread_block(cl, keys[0], args, keys, ids, block_ms,
                            deadline);
    }
    push(args, to_bytes("COUNT"));
    push(args, to_bytes(to_str(n)));
    return cxread_block(cl, keys[0], args, keys, ids, block_ms,
                        deadline);
}

fn cxread_block(cl: Cluster, key: str, args: [bytes], keys: [str],
                ids: [str], block_ms: opt[int],
                deadline: until) -> result[opt[[StreamRead]], str] {
    guard let ms = block_ms else {
        return cxread_run(cl, key, args, keys, ids, deadline);
    }
    push(args, to_bytes("BLOCK"));
    push(args, to_bytes(to_str(ms)));
    return cxread_run(cl, key, args, keys, ids, deadline);
}

fn cxread_run(cl: Cluster, key: str, args: [bytes], keys: [str],
              ids: [str],
              deadline: until) -> result[opt[[StreamRead]], str] {
    push(args, to_bytes("STREAMS"));
    for k in keys {
        push(args, to_bytes(k));
    }
    for id in ids {
        push(args, to_bytes(id));
    }
    let r = cluster_do(cl, key, args, deadline);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    if reply.kind == REPLY_ARRAY && reply.is_nil {
        let nothing: opt[[StreamRead]] = none;
        return ok(nothing);
    }
    guard let items = as_array(reply, "XREAD") else let e = err_of(as_array(reply, "XREAD")) {
        return err(e);
    }
    let out: [StreamRead] = [];
    for it in items {
        if it.kind != REPLY_ARRAY || it.is_nil || len(it.items) != 2 {
            return err("XREAD: bad key block");
        }
        if it.items[0].kind != REPLY_BULK {
            return err("XREAD: bad key name");
        }
        guard let kb = it.items[0].bulk else {
            return err("XREAD: nil key");
        }
        if it.items[1].kind != REPLY_ARRAY || it.items[1].is_nil {
            return err("XREAD: bad entry list");
        }
        let entries: [StreamEntry] = [];
        for e in it.items[1].items {
            let er = parse_entry(e, "XREAD");
            guard let entry = er else let e = err_of(er) {
                return err(e);
            }
            push(entries, entry);
        }
        push(out, StreamRead { key: to_str(kb), entries: entries });
    }
    return ok(some(out));
}
