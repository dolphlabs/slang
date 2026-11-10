// A MySQL and MariaDB client: the client/server protocol over TCP, TLS or
// a Unix socket, with prepared statements, streamed results and a pool.
//
//     import "mysql";
//
//     let cr = mysql.connect("mysql://app:secret@db.internal:3306/shop", deadline);
//     guard let c = cr else let e = err_of(cr) { panic(e); }
//     let r = mysql.query(c, "SELECT id, name FROM users WHERE id = ?", [mysql.arg_int(42)], deadline);
//     guard let rows = r else let e = err_of(r) { panic(e); }
//     let users: result[[User], str] = mysql.rows_as(rows);
//     mysql.exec(c, "CREATE TABLE t (id INT); INSERT INTO t VALUES (1)", deadline);
//
// query() sends its SQL as a prepared statement (cached per connection),
// so parameters travel apart from the SQL text and can never be read as
// SQL, and exactly one statement runs. exec() sends SQL as text, several
// statements allowed, for migrations and schema.
//
// The API mirrors pg's: the same Rows getters, rows_as, stream/next_row,
// and a pool. Every length the server sends is bounded.

import "crypto";
import "encoding";
import "fs";
import "net";
import "strings";
import "time";

// ---- limits and protocol constants ------------------------------------------------

let MAX_PACKET = 268435456;     // one logical packet (after joining 16 MiB pieces), 256 MiB
let MAX_RESULT = 268435456;     // all cells of one result
let READ_CHUNK = 65536;
let MAX_READ = 4194304;
let STMT_CACHE = 256;
let MAX_STMT_CACHE = 65536;

let COM_QUIT = 1;
let COM_QUERY = 3;
let COM_PING = 14;
let COM_STMT_PREPARE = 22;
let COM_STMT_EXECUTE = 23;
let COM_STMT_CLOSE = 25;

// capability flags
let CLIENT_LONG_PASSWORD = 1;
let CLIENT_LONG_FLAG = 4;
let CLIENT_CONNECT_WITH_DB = 8;
let CLIENT_PROTOCOL_41 = 512;
let CLIENT_SSL = 2048;
let CLIENT_TRANSACTIONS = 8192;
let CLIENT_SECURE_CONNECTION = 32768;
let CLIENT_MULTI_STATEMENTS = 65536;
let CLIENT_MULTI_RESULTS = 131072;
let CLIENT_PS_MULTI_RESULTS = 262144;
let CLIENT_PLUGIN_AUTH = 524288;
let CLIENT_PLUGIN_AUTH_LENENC = 2097152;
let CLIENT_DEPRECATE_EOF = 16777216;

// server status flags
let STATUS_IN_TRANS = 1;
let STATUS_MORE_RESULTS = 8;

// utf8mb4_general_ci: understood by every MySQL 5.5+ and MariaDB
let CHARSET_UTF8MB4 = 45;

// ---- configuration ------------------------------------------------------------------

pub gc struct Config {
    host: str,      // a host name, or a Unix socket path starting with /
    port: int,
    user: str,
    password: str,
    database: str,
    // "disable" or "require" (TLS with the certificate and host verified)
    sslmode: str,
    ca_path: str,
    // Full authentication with caching_sha2_password or sha256_password
    // over a connection without TLS encrypts the password to the server's
    // RSA key. The key is taken from server_public_key (a PEM file) if
    // set; fetching it from the server is allowed only with
    // allow_public_key_retrieval, since a man in the middle can send his
    // own. Over TLS neither is needed.
    server_public_key: str,
    allow_public_key_retrieval: bool,
    // sent as SET time_zone after connecting, "" to leave the server's
    time_zone: str,
    statement_cache: int,
    tls_ctx: rawptr,
}

fn is_loopback(host: str) -> bool {
    return host == "localhost" || host == "::1" || strings.has_prefix(host, "127.");
}

// mysql://user:password@host:port/database?sslmode=require
//
// Parameters: sslmode (disable, require; verify-full is require),
// sslrootcert (a CA bundle), server_public_key (a PEM file),
// allow_public_key_retrieval (true), time_zone (e.g. +00:00),
// statement_cache (0 to 65536). Any other parameter is an error: a
// misspelt sslmode silently dropped would connect in the clear.
//
// TLS is required by default, except to a loopback host or over a Unix
// socket (host=/path/to/mysqld.sock, or the path percent-encoded as the
// host), where it is off.
pub fn parse_url(url: str) -> result[Config, str] {
    let rest = "";
    if strings.has_prefix(url, "mysql://") {
        rest = strings.slice(url, 8, len(url));
    } else if strings.has_prefix(url, "mariadb://") {
        rest = strings.slice(url, 10, len(url));
    } else {
        return err("mysql: url must begin with mysql:// or mariadb://");
    }
    let query = "";
    let q = strings.find(rest, "?");
    if q >= 0 {
        query = strings.slice(rest, q + 1, len(rest));
        rest = strings.slice(rest, 0, q);
    }
    let database = "";
    let slash = strings.find(rest, "/");
    let authority = rest;
    if slash >= 0 {
        let dr = encoding.url_decode(strings.slice(rest, slash + 1, len(rest)));
        guard let d = dr else let e = err_of(dr) { return err("mysql: bad database name in url: " + e); }
        database = d;
        authority = strings.slice(rest, 0, slash);
    }
    let user = "";
    let password = "";
    let at = strings.rfind(authority, "@");
    if at >= 0 {
        let userinfo = strings.slice(authority, 0, at);
        authority = strings.slice(authority, at + 1, len(authority));
        let colon = strings.find(userinfo, ":");
        let raw_user = userinfo;
        if colon >= 0 {
            raw_user = strings.slice(userinfo, 0, colon);
            let pr = encoding.url_decode(strings.slice(userinfo, colon + 1, len(userinfo)));
            guard let p = pr else let e = err_of(pr) { return err("mysql: bad password in url: " + e); }
            password = p;
        }
        let ur = encoding.url_decode(raw_user);
        guard let u = ur else let e = err_of(ur) { return err("mysql: bad user name in url: " + e); }
        user = u;
    }
    let hr = encoding.url_decode(authority);
    guard let hostport = hr else let e = err_of(hr) { return err("mysql: bad host in url: " + e); }
    let host = hostport;
    let port = 3306;
    if !strings.has_prefix(hostport, "/") {
        if strings.has_prefix(hostport, "[") {
            let close = strings.find(hostport, "]");
            if close < 0 {
                return err("mysql: unterminated IPv6 literal in url");
            }
            host = strings.slice(hostport, 1, close);
            let tail = strings.slice(hostport, close + 1, len(hostport));
            if tail != "" {
                if !strings.has_prefix(tail, ":") {
                    return err("mysql: junk after IPv6 literal in url");
                }
                let pr = to_int(strings.slice(tail, 1, len(tail)));
                guard let p = pr else { return err("mysql: bad port in url"); }
                port = p;
            }
        } else {
            let colon = strings.rfind(hostport, ":");
            if colon >= 0 {
                let pr = to_int(strings.slice(hostport, colon + 1, len(hostport)));
                guard let p = pr else { return err("mysql: bad port in url"); }
                port = p;
                host = strings.slice(hostport, 0, colon);
            }
        }
    }
    let cfg = Config { host: host, port: port, user: user, password: password, database: database,
                       sslmode: "", ca_path: "", server_public_key: "", allow_public_key_retrieval: false,
                       time_zone: "", statement_cache: STMT_CACHE, tls_ctx: nullptr };
    if query != "" {
        for kv in strings.split(query, "&") {
            if kv == "" {
                continue;
            }
            let eq = strings.find(kv, "=");
            if eq < 0 {
                return err("mysql: url parameter without a value: " + kv);
            }
            let k = strings.slice(kv, 0, eq);
            let vr = encoding.url_decode(strings.slice(kv, eq + 1, len(kv)));
            guard let v = vr else let e = err_of(vr) { return err("mysql: bad url parameter " + k + ": " + e); }
            if k == "sslmode" || k == "ssl-mode" {
                let low = strings.to_lower(v);
                if low == "disable" || low == "disabled" {
                    cfg.sslmode = "disable";
                } else if low == "require" || low == "required" || low == "verify-full" || low == "verify_identity" {
                    cfg.sslmode = "require";
                } else {
                    return err("mysql: sslmode must be disable or require (got " + v + "; prefer and verify-ca are refused: " +
                               "one falls back to cleartext, the other skips the host name)");
                }
            } else if k == "sslrootcert" {
                cfg.ca_path = v;
            } else if k == "server_public_key" {
                cfg.server_public_key = v;
            } else if k == "allow_public_key_retrieval" {
                cfg.allow_public_key_retrieval = v == "true" || v == "1";
            } else if k == "time_zone" {
                if strings.contains(v, "'") || strings.contains(v, "\\") {
                    return err("mysql: bad time_zone");
                }
                cfg.time_zone = v;
            } else if k == "host" {
                cfg.host = v;
            } else if k == "port" {
                let pr = to_int(v);
                guard let p = pr else { return err("mysql: bad port parameter"); }
                cfg.port = p;
            } else if k == "statement_cache" {
                let nr = to_int(v);
                guard let n = nr else { return err("mysql: bad statement_cache"); }
                if n < 0 || n > MAX_STMT_CACHE {
                    return err("mysql: statement_cache must be 0 to " + to_str(MAX_STMT_CACHE));
                }
                cfg.statement_cache = n;
            } else {
                return err("mysql: unknown url parameter " + k);
            }
        }
    }
    if cfg.host == "" {
        return err("mysql: url has no host");
    }
    if cfg.port <= 0 || cfg.port > 65535 {
        return err("mysql: port out of range");
    }
    if cfg.user == "" {
        return err("mysql: url has no user");
    }
    let unix = strings.has_prefix(cfg.host, "/");
    if cfg.sslmode == "" {
        if unix || is_loopback(cfg.host) {
            cfg.sslmode = "disable";
        } else {
            cfg.sslmode = "require";
        }
    }
    if unix && cfg.sslmode == "require" {
        return err("mysql: TLS is not used over a Unix socket; drop sslmode=require");
    }
    return ok(cfg);
}

// ---- the connection -----------------------------------------------------------------

gc struct Stmt {
    id: int,
    params: int,
    columns: [str],
    types: [int],
    raw_types: [int],
    used: int,
}

pub gc struct Conn {
    cfg: Config,
    fd: int,
    ssl: rawptr,
    buf: bytes,
    pos: int,
    // bumped whenever buf is replaced (see Rows' chunks)
    gen: int,
    seq: int,
    // the packet next_packet last read: where its payload sits in buf
    pstart: int,
    plen: int,
    // a packet over 16 MiB, joined from its pieces
    joined: bytes,
    caps: int,
    server_version: str,
    conn_id: int,
    // the server status flags of the last OK or EOF
    status: int,
    last_insert_id: int,
    affected: int,
    warnings: int,
    broken: bool,
    why: str,
    closed: bool,
    in_pool: bool,
    // 1 while a streamed result is open
    mode: int,
    stream_id: int,
    lock: mutex,
    stmts: map[str]Stmt,
    stmt_tick: int,
    stmt_close: [int],
}

pub fn connect(url: str, deadline: until) -> result[Conn, str] {
    let cr = parse_url(url);
    guard let cfg = cr else let e = err_of(cr) { return err(e); }
    return connect_config(cfg, deadline);
}

// The deadline covers the whole connection: the lookup, the TCP connect,
// TLS, authentication and any time_zone setting.
pub fn connect_config(cfg: Config, deadline: until) -> result[Conn, str] {
    let c = Conn { cfg: cfg, fd: -1, ssl: nullptr, buf: strings.bytes_zero(0), pos: 0, gen: 0, seq: 0,
                   pstart: 0, plen: 0, joined: strings.bytes_zero(0), caps: 0, server_version: "", conn_id: 0,
                   status: 0, last_insert_id: 0, affected: 0, warnings: 0, broken: false, why: "", closed: false,
                   in_pool: false, mode: 0, stream_id: 0, lock: make_mutex(), stmts: {}, stmt_tick: 0,
                   stmt_close: [] };
    if strings.has_prefix(cfg.host, "/") {
        let ur = net.dial_unix(cfg.host, deadline);
        guard let ufd = ur else let e = err_of(ur) { return err(dial_error(e, cfg.host)); }
        c.fd = ufd;
    } else {
        let dr = net.dial_until(cfg.host, cfg.port, deadline);
        guard let fd = dr else let e = err_of(dr) { return err(dial_error(e, cfg.host)); }
        c.fd = fd;
    }
    let hr = handshake(c, deadline);
    guard let _h = hr else let e = err_of(hr) {
        close_transport(c);
        c.closed = true;
        return err(e);
    }
    if cfg.time_zone != "" {
        let tr = exec(c, "SET time_zone = '" + cfg.time_zone + "'", deadline);
        guard let _t = tr else let e = err_of(tr) {
            close(c);
            return err(e);
        }
    }
    return ok(c);
}

fn dial_error(e: str, host: str) -> str {
    if e == "timeout" {
        return e;
    }
    return "mysql: dial " + host + ": " + e;
}

// Ends the session politely (COM_QUIT) and closes the socket.
pub fn close(c: Conn) {
    mutex_lock(c.lock);
    if !c.closed && !c.broken {
        c.seq = 0;
        send_packet(c, cmd_bytes(COM_QUIT, b""), until_of(time.mono() + 1000000000));
        close_transport(c);
    }
    c.closed = true;
    mutex_unlock(c.lock);
}

// Is the connection still usable? False once closed or broken.
pub fn usable(c: Conn) -> bool {
    return !c.closed && !c.broken;
}

// Inside a transaction (as the server last reported)?
pub fn in_transaction(c: Conn) -> bool {
    return (c.status & STATUS_IN_TRANS) != 0;
}

// The server's version string ("8.4.3", "11.4.4-MariaDB-...").
pub fn server_version(c: Conn) -> str {
    return c.server_version;
}

// The server's id for this connection (what KILL takes).
pub fn connection_id(c: Conn) -> int {
    return c.conn_id;
}

// The AUTO_INCREMENT value the last statement generated, and the rows it
// changed, as the server reported them.
pub fn last_insert_id(c: Conn) -> int {
    return c.last_insert_id;
}

pub fn affected_rows(c: Conn) -> int {
    return c.affected;
}

// Asks the server whether it is there (COM_PING).
pub fn ping(c: Conn, deadline: until) -> result[bool, str] {
    let ur = check_usable(c, deadline);
    guard let _u = ur else let e = err_of(ur) { return err(e); }
    c.seq = 0;
    let sr = send_packet(c, cmd_bytes(COM_PING, b""), deadline);
    guard let _s = sr else let e = err_of(sr) { return err(fail(c, e)); }
    let pr = read_ok(c, deadline);
    guard let _p = pr else let e = err_of(pr) { return err(fail_unless_server(c, e)); }
    return ok(true);
}

// ---- transport ------------------------------------------------------------------------

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

fn close_transport(c: Conn) {
    if c.ssl != nullptr {
        net.tls_close(c.ssl);
        c.ssl = nullptr;
        c.fd = -1;
        return;
    }
    if c.fd >= 0 {
        net.close(c.fd);
        c.fd = -1;
    }
}

fn write_all(c: Conn, data: bytes, deadline: until) -> result[bool, str] {
    let off = 0;
    while off < len(data) {
        let chunk = data;
        if off > 0 {
            chunk = data[off..];
        }
        let r = tr_send(c, chunk, deadline);
        guard let n = r else let e = err_of(r) { return err(e); }
        if n <= 0 {
            return err("server closed the connection");
        }
        off += n as int;
    }
    return ok(true);
}

// ---- packets --------------------------------------------------------------------------

fn le16(b: bytes, i: int) -> int {
    return b[i] | (b[i + 1] << 8);
}

fn le24(b: bytes, i: int) -> int {
    return b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);
}

fn le32(b: bytes, i: int) -> int {
    return b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);
}

fn le64(b: bytes, i: int) -> int {
    let v = 0;
    let k = 7;
    while k >= 0 {
        v = (v << 8) | b[i + k];
        k -= 1;
    }
    return v;
}

fn put_le(n: int, width: int) -> bytes {
    let b = strings.bytes_zero(width);
    for k in 0..width {
        b[k] = (n >> (8 * k)) & 255;
    }
    return b;
}

// A length-encoded integer.
fn lenenc(n: int) -> bytes {
    if n < 251 {
        return put_le(n, 1);
    }
    if n < 65536 {
        return cat([b"\xfc", put_le(n, 2)]);
    }
    if n < 16777216 {
        return cat([b"\xfd", put_le(n, 3)]);
    }
    return cat([b"\xfe", put_le(n, 8)]);
}

fn cat(xs: [bytes]) -> bytes {
    return strings.join_bytes(xs, b"");
}

fn cmd_bytes(cmd: int, body: bytes) -> bytes {
    let h = strings.bytes_zero(1);
    h[0] = cmd;
    return cat([h, body]);
}

// Writes payload as packets (pieces of 16 MiB - 1 and a shorter last
// one), numbering them from c.seq.
fn send_packet(c: Conn, payload: bytes, deadline: until) -> result[bool, str] {
    let parts: [bytes] = [];
    let off = 0;
    while true {
        let n = len(payload) - off;
        if n > 16777215 {
            n = 16777215;
        }
        let h = put_le(n, 4);
        h[3] = c.seq & 255;
        c.seq += 1;
        push(parts, h);
        if n > 0 {
            push(parts, payload[off..off + n]);
        }
        off += n;
        if n < 16777215 {
            break;
        }
    }
    let wr = write_all(c, cat(parts), deadline);
    guard let _w = wr else let e = err_of(wr) { return err(e); }
    return ok(true);
}

// Ensures need unread bytes; "" or the error. On failure what was read
// stays buffered.
fn fill(c: Conn, need: int, deadline: until) -> str {
    let have = len(c.buf) - c.pos;
    if have >= need {
        return "";
    }
    let parts: [bytes] = [];
    if have > 0 {
        push(parts, c.buf[c.pos..]);
    }
    c.buf = strings.bytes_zero(0);
    c.pos = 0;
    c.gen += 1;
    while have < need {
        let want = need - have;
        if want < READ_CHUNK {
            want = READ_CHUNK;
        }
        if want > MAX_READ {
            want = MAX_READ;
        }
        let rr = tr_recv(c, want, deadline);
        guard let got = rr else let e = err_of(rr) {
            c.buf = cat(parts);
            return e;
        }
        if len(got) == 0 {
            c.buf = cat(parts);
            return "server closed the connection";
        }
        push(parts, got);
        have += len(got);
    }
    if len(parts) == 1 {
        c.buf = parts[0];
    } else {
        c.buf = cat(parts);
    }
    return "";
}

// The next packet's payload, as c.buf[c.pstart..c.pstart + c.plen] (or,
// joined from 16 MiB pieces, c.joined with pstart 0, and buf switched to
// it). Returns "" or the error.
fn next_packet(c: Conn, deadline: until) -> str {
    let e = fill(c, 4, deadline);
    if e != "" {
        return e;
    }
    let n = le24(c.buf, c.pos);
    let seq = c.buf[c.pos + 3];
    if seq != (c.seq & 255) {
        return "mysql: protocol error: packet sequence " + to_str(seq) + ", expected " + to_str(c.seq & 255);
    }
    c.seq += 1;
    let e2 = fill(c, 4 + n, deadline);
    if e2 != "" {
        return e2;
    }
    if n < 16777215 {
        c.pstart = c.pos + 4;
        c.plen = n;
        c.pos += 4 + n;
        return "";
    }
    // a payload of 16 MiB or more comes in pieces: join them
    let parts: [bytes] = [c.buf[c.pos + 4..c.pos + 4 + n]];
    let total = n;
    c.pos += 4 + n;
    while true {
        let e3 = fill(c, 4, deadline);
        if e3 != "" {
            return e3;
        }
        let m = le24(c.buf, c.pos);
        if c.buf[c.pos + 3] != (c.seq & 255) {
            return "mysql: protocol error: packet sequence";
        }
        c.seq += 1;
        total += m;
        if total > MAX_PACKET {
            return "mysql: protocol error: a packet over " + to_str(MAX_PACKET) + " bytes";
        }
        let e4 = fill(c, 4 + m, deadline);
        if e4 != "" {
            return e4;
        }
        push(parts, c.buf[c.pos + 4..c.pos + 4 + m]);
        c.pos += 4 + m;
        if m < 16777215 {
            break;
        }
    }
    // the joined payload becomes a buffer of its own, so cells can point
    // into it like any other
    let rest = c.buf[c.pos..];
    c.joined = cat(parts);
    c.buf = cat([c.joined, rest]);
    c.pos = total;
    c.gen += 1;
    c.pstart = 0;
    c.plen = total;
    return "";
}

fn payload(c: Conn) -> bytes {
    return c.buf[c.pstart..c.pstart + c.plen];
}

fn first_byte(c: Conn) -> int {
    if c.plen == 0 {
        return -1;
    }
    return c.buf[c.pstart];
}

// A cursor over a payload.
gc struct Cur {
    b: bytes,
    i: int,
    end: int,
    bad: bool,
}

fn cur_of(b: bytes, start: int, end: int) -> Cur {
    return Cur { b: b, i: start, end: end, bad: false };
}

fn get_u8(p: Cur) -> int {
    if p.i + 1 > p.end {
        p.bad = true;
        return 0;
    }
    p.i += 1;
    return p.b[p.i - 1];
}

fn get_fixed(p: Cur, w: int) -> int {
    if p.i + w > p.end {
        p.bad = true;
        p.i = p.end;
        return 0;
    }
    let v = 0;
    let k = w - 1;
    while k >= 0 {
        v = (v << 8) | p.b[p.i + k];
        k -= 1;
    }
    p.i += w;
    return v;
}

// A length-encoded integer; -1 for the NULL marker (0xfb).
fn get_lenenc(p: Cur) -> int {
    let f = get_u8(p);
    if f < 251 {
        return f;
    }
    if f == 251 {
        return -1;
    }
    if f == 252 {
        return get_fixed(p, 2);
    }
    if f == 253 {
        return get_fixed(p, 3);
    }
    if f == 254 {
        let v = get_fixed(p, 8);
        if v < 0 {
            p.bad = true;
            return 0;
        }
        return v;
    }
    p.bad = true;
    return 0;
}

fn get_str(p: Cur, n: int) -> str {
    if n < 0 || p.i + n > p.end {
        p.bad = true;
        p.i = p.end;
        return "";
    }
    let s = strings.from_bytes(p.b, p.i, p.i + n);
    p.i += n;
    return s;
}

fn get_lenenc_str(p: Cur) -> str {
    let n = get_lenenc(p);
    if n < 0 {
        return "";
    }
    return get_str(p, n);
}

fn get_cstr(p: Cur) -> str {
    let k = p.i;
    while k < p.end && p.b[k] != 0 {
        k += 1;
    }
    if k >= p.end {
        p.bad = true;
        let s = strings.from_bytes(p.b, p.i, p.end);
        p.i = p.end;
        return s;
    }
    let s = strings.from_bytes(p.b, p.i, k);
    p.i = k + 1;
    return s;
}

fn take_bytes(p: Cur, n: int) -> bytes {
    if n < 0 || p.i + n > p.end {
        p.bad = true;
        p.i = p.end;
        return strings.bytes_zero(0);
    }
    let b = p.b[p.i..p.i + n];
    p.i += n;
    return b;
}

fn cur_payload(c: Conn) -> Cur {
    return cur_of(c.buf, c.pstart, c.pstart + c.plen);
}

// ---- server replies ------------------------------------------------------------------

// "mysql: ERROR 1062 (23000): Duplicate entry '1' for key 'PRIMARY'"
fn error_text(c: Conn) -> str {
    let p = cur_payload(c);
    get_u8(p);
    let code = get_fixed(p, 2);
    let state = "";
    if p.i < p.end && p.b[p.i] == 35 {
        p.i += 1;
        state = get_str(p, 5);
    }
    let message = strings.from_bytes(p.b, p.i, p.end);
    if state == "" {
        return "mysql: ERROR " + to_str(code) + ": " + message;
    }
    return "mysql: ERROR " + to_str(code) + " (" + state + "): " + message;
}

// The SQLSTATE of an error from this package ("23000"), or "" when the
// error did not come from the server.
pub fn sqlstate(e: str) -> str {
    let open = strings.find(e, " (");
    if !strings.has_prefix(e, "mysql: ERROR ") || open < 0 || strings.slice(e, open + 7, open + 10) != "): " {
        return "";
    }
    return strings.slice(e, open + 2, open + 7);
}

// The server's error number (1062 for a duplicate key), or 0.
pub fn error_code(e: str) -> int {
    if !strings.has_prefix(e, "mysql: ERROR ") {
        return 0;
    }
    let rest = strings.slice(e, 13, len(e));
    let k = 0;
    let b = to_bytes(rest);
    while k < len(b) && b[k] >= 48 && b[k] <= 57 {
        k += 1;
    }
    return to_int(strings.slice(rest, 0, k)) ?? 0;
}

// An OK packet (0x00, or 0xfe ending a result with DEPRECATE_EOF):
// affected rows, insert id, status, warnings.
fn take_ok(c: Conn) {
    let p = cur_payload(c);
    get_u8(p);
    c.affected = get_lenenc(p);
    c.last_insert_id = get_lenenc(p);
    c.status = get_fixed(p, 2);
    c.warnings = get_fixed(p, 2);
}

// An EOF packet (0xfe, short): warnings, status.
fn take_eof(c: Conn) {
    let p = cur_payload(c);
    get_u8(p);
    if c.plen >= 5 {
        c.warnings = get_fixed(p, 2);
        c.status = get_fixed(p, 2);
    }
}

fn is_eof(c: Conn) -> bool {
    return first_byte(c) == 254 && c.plen < 9;
}

// The end of a result's rows: an EOF, or with DEPRECATE_EOF an OK packet
// with the 0xfe header (told from a row by its length).
fn is_end_of_rows(c: Conn) -> bool {
    if first_byte(c) != 254 {
        return false;
    }
    if (c.caps & CLIENT_DEPRECATE_EOF) != 0 {
        return c.plen < 16777215;
    }
    return c.plen < 9;
}

fn take_end_of_rows(c: Conn) {
    if (c.caps & CLIENT_DEPRECATE_EOF) != 0 {
        take_ok(c);
    } else {
        take_eof(c);
    }
}

// An OK, or the server's error.
fn read_ok(c: Conn, deadline: until) -> result[bool, str] {
    let e = next_packet(c, deadline);
    if e != "" {
        return err(e);
    }
    let f = first_byte(c);
    if f == 0 {
        take_ok(c);
        return ok(true);
    }
    if f == 255 {
        return err(error_text(c));
    }
    return err("mysql: protocol error: expected OK, got 0x" + encoding.hex_encode(put_le(f, 1)));
}

// ---- failure handling --------------------------------------------------------------------

fn check_usable(c: Conn, deadline: until) -> result[bool, str] {
    if c.closed {
        return err("mysql: connection is closed");
    }
    if c.broken {
        return err("mysql: connection is broken: " + c.why);
    }
    if c.mode == 1 {
        return err("mysql: connection is busy: a streamed result is still open (read it to the end, or mysql.stream_close)");
    }
    if until_hit(deadline) {
        return err("timeout");
    }
    return ok(true);
}

// The stream is at an unknown offset: the connection is not used again.
// After a timeout the server may still be running the statement, so it
// is killed from a second connection.
fn break_conn(c: Conn, why: str) {
    if c.broken || c.closed {
        return;
    }
    c.broken = true;
    c.why = why;
    c.mode = 0;
    if why == "timeout" && c.conn_id != 0 {
        spawn kill_later(c.cfg, c.conn_id);
    }
    close_transport(c);
}

fn kill_later(cfg: Config, id: int) {
    let cr = connect_config(cfg, until_of(time.mono() + 5000000000));
    guard let k = cr else { return; }
    exec(k, "KILL QUERY " + to_str(id), until_of(time.mono() + 5000000000));
    close(k);
}

fn fail(c: Conn, e: str) -> str {
    break_conn(c, e);
    return e;
}

// A server error leaves the stream at a packet boundary: the connection
// stays good. Anything else breaks it.
fn fail_unless_server(c: Conn, e: str) -> str {
    if strings.has_prefix(e, "mysql: ERROR ") {
        c.mode = 0;
        return e;
    }
    return fail(c, e);
}

// ---- authentication -------------------------------------------------------------------

fn xor_bytes(a: bytes, b: bytes) -> bytes {
    let out = strings.bytes_zero(len(a));
    for k in 0..len(a) {
        out[k] = a[k] ^ b[k % len(b)];
    }
    return out;
}

// mysql_native_password: SHA1(pw) XOR SHA1(nonce + SHA1(SHA1(pw))).
pub fn native_password_scramble(password: str, nonce: bytes) -> bytes {
    if password == "" {
        return strings.bytes_zero(0);
    }
    let h1 = crypto.sha1(to_bytes(password));
    let h2 = crypto.sha1(h1);
    return xor_bytes(h1, crypto.sha1(cat([nonce, h2])));
}

// caching_sha2_password: SHA256(pw) XOR SHA256(SHA256(SHA256(pw)) + nonce).
pub fn sha2_password_scramble(password: str, nonce: bytes) -> bytes {
    if password == "" {
        return strings.bytes_zero(0);
    }
    let h1 = crypto.sha256(to_bytes(password));
    let h2 = crypto.sha256(h1);
    return xor_bytes(h1, crypto.sha256(cat([h2, nonce])));
}

// The first response a plugin sends.
fn auth_response(c: Conn, plugin: str, nonce: bytes) -> result[bytes, str] {
    if plugin == "mysql_native_password" {
        return ok(native_password_scramble(c.cfg.password, nonce));
    }
    if plugin == "caching_sha2_password" {
        return ok(sha2_password_scramble(c.cfg.password, nonce));
    }
    if plugin == "sha256_password" {
        if c.cfg.password == "" {
            return ok(b"\x00");
        }
        if c.ssl != nullptr {
            return ok(cat([to_bytes(c.cfg.password), b"\x00"]));
        }
        // ask for the key (or use the configured one) after this
        return ok(b"\x01");
    }
    if plugin == "mysql_clear_password" {
        if c.ssl == nullptr {
            return err("mysql: the server asks for the password in cleartext (mysql_clear_password) over a connection without TLS; refused");
        }
        return ok(cat([to_bytes(c.cfg.password), b"\x00"]));
    }
    return err("mysql: authentication plugin " + plugin + " is not supported " +
               "(supported: mysql_native_password, caching_sha2_password, sha256_password, mysql_clear_password over TLS)");
}

fn handshake(c: Conn, deadline: until) -> result[bool, str] {
    c.seq = 0;
    let e = next_packet(c, deadline);
    if e != "" {
        return err(dial_error(e, c.cfg.host));
    }
    if first_byte(c) == 255 {
        return err(error_text(c));
    }
    let p = cur_payload(c);
    let proto = get_u8(p);
    if proto != 10 {
        return err("mysql: unsupported protocol version " + to_str(proto) + "; is this a MySQL server?");
    }
    c.server_version = get_cstr(p);
    c.conn_id = get_fixed(p, 4);
    let nonce1 = take_bytes(p, 8);
    get_u8(p);
    let caps = get_fixed(p, 2);
    get_u8(p);
    c.status = get_fixed(p, 2);
    caps = caps | (get_fixed(p, 2) << 16);
    let auth_len = get_u8(p);
    take_bytes(p, 10);
    let n2 = auth_len - 8;
    if n2 < 13 {
        n2 = 13;
    }
    let nonce2 = take_bytes(p, n2);
    let plugin = "";
    if (caps & CLIENT_PLUGIN_AUTH) != 0 && p.i < p.end {
        plugin = get_cstr(p);
    }
    if p.bad {
        return err("mysql: protocol error: malformed handshake");
    }
    let need = CLIENT_PROTOCOL_41 | CLIENT_SECURE_CONNECTION | CLIENT_PLUGIN_AUTH;
    if (caps & need) != need {
        return err("mysql: the server is too old (it lacks protocol 4.1 authentication)");
    }
    // the nonce is 20 bytes; the second part ends with a NUL
    let nonce = cat([nonce1, nonce2]);
    if len(nonce) > 20 {
        nonce = nonce[0..20];
    }
    let mine = CLIENT_LONG_PASSWORD | CLIENT_LONG_FLAG | CLIENT_PROTOCOL_41 | CLIENT_TRANSACTIONS |
               CLIENT_SECURE_CONNECTION | CLIENT_MULTI_STATEMENTS | CLIENT_MULTI_RESULTS | CLIENT_PS_MULTI_RESULTS |
               CLIENT_PLUGIN_AUTH | CLIENT_PLUGIN_AUTH_LENENC | CLIENT_DEPRECATE_EOF;
    if c.cfg.database != "" {
        mine = mine | CLIENT_CONNECT_WITH_DB;
    }
    if c.cfg.sslmode == "require" {
        if (caps & CLIENT_SSL) == 0 {
            return err("mysql: server " + c.cfg.host + " does not support TLS; add sslmode=disable to the url to connect without it");
        }
        mine = mine | CLIENT_SSL;
    }
    // only what both sides have
    c.caps = mine & (caps | CLIENT_SSL);
    let fixed = cat([put_le(c.caps, 4), put_le(16777216, 4), put_le(CHARSET_UTF8MB4, 1), strings.bytes_zero(23)]);
    if c.cfg.sslmode == "require" {
        // SSLRequest: the response's fixed part, then TLS on the same socket
        let sr = send_packet(c, fixed, deadline);
        guard let _s = sr else let e2 = err_of(sr) { return err(e2); }
        if len(c.buf) - c.pos > 0 {
            // bytes before the TLS handshake would be read as if encrypted
            return err("mysql: the server sent data before the TLS handshake");
        }
        if c.cfg.tls_ctx == nullptr {
            let cr = net.tls_client_ctx(c.cfg.ca_path);
            guard let ctx = cr else let e3 = err_of(cr) { return err("mysql: tls context: " + e3); }
            c.cfg.tls_ctx = ctx;
        }
        let ur = net.tls_upgrade_until(c.fd, c.cfg.host, c.cfg.tls_ctx, deadline);
        guard let ssl = ur else let e4 = err_of(ur) {
            if e4 == "timeout" {
                return err(e4);
            }
            return err("mysql: tls " + c.cfg.host + ": " + e4);
        }
        c.ssl = ssl;
    }
    if plugin == "" {
        plugin = "mysql_native_password";
    }
    let ar = auth_response(c, plugin, nonce);
    guard let resp = ar else let e5 = err_of(ar) { return err(e5); }
    let body = cat([fixed, to_bytes(c.cfg.user), b"\x00", lenenc(len(resp)), resp]);
    if c.cfg.database != "" {
        body = cat([body, to_bytes(c.cfg.database), b"\x00"]);
    }
    body = cat([body, to_bytes(plugin), b"\x00"]);
    let sr2 = send_packet(c, body, deadline);
    guard let _s2 = sr2 else let e6 = err_of(sr2) { return err(e6); }
    return auth_loop(c, plugin, nonce, deadline);
}

// The server's answers until OK: plugin switches, caching_sha2's fast
// and full paths, public keys.
fn auth_loop(c: Conn, plugin0: str, nonce0: bytes, deadline: until) -> result[bool, str] {
    let plugin = plugin0;
    let nonce = nonce0;
    let switches = 0;
    while true {
        let e = next_packet(c, deadline);
        if e != "" {
            return err(e);
        }
        let f = first_byte(c);
        if f == 0 {
            take_ok(c);
            return ok(true);
        }
        if f == 255 {
            return err(error_text(c));
        }
        if f == 254 {
            // AuthSwitchRequest: another plugin, another nonce
            switches += 1;
            if switches > 2 {
                return err("mysql: the server switched authentication plugins repeatedly");
            }
            let p = cur_payload(c);
            get_u8(p);
            plugin = get_cstr(p);
            let rest = take_bytes(p, p.end - p.i);
            if len(rest) > 0 && rest[len(rest) - 1] == 0 {
                rest = rest[0..len(rest) - 1];
            }
            nonce = rest;
            let ar = auth_response(c, plugin, nonce);
            guard let resp = ar else let e2 = err_of(ar) { return err(e2); }
            let sr = send_packet(c, resp, deadline);
            guard let _s = sr else let e3 = err_of(sr) { return err(e3); }
            continue;
        }
        if f == 1 {
            // AuthMoreData
            let more = c.buf[c.pstart + 1..c.pstart + c.plen];
            if plugin == "caching_sha2_password" && len(more) == 1 && more[0] == 3 {
                // fast authentication succeeded; an OK follows
                continue;
            }
            if plugin == "caching_sha2_password" && len(more) == 1 && more[0] == 4 {
                let fr = full_auth(c, nonce, deadline, b"\x02");
                guard let _f = fr else let e4 = err_of(fr) { return err(e4); }
                continue;
            }
            if strings.contains(to_str(more), "-----BEGIN") {
                let sr = send_encrypted(c, to_str(more), nonce, deadline);
                guard let _s = sr else let e5 = err_of(sr) { return err(e5); }
                continue;
            }
            if plugin == "sha256_password" {
                let fr = full_auth(c, nonce, deadline, b"\x01");
                guard let _f = fr else let e6 = err_of(fr) { return err(e6); }
                continue;
            }
            return err("mysql: protocol error: unexpected authentication data");
        }
        return err("mysql: protocol error: unexpected packet during authentication");
    }
    return err("unreachable");
}

// The password itself, for a server that does not have it cached: in
// cleartext over TLS, else encrypted to the server's RSA key (from the
// configured file, or asked for with `ask` when that is allowed).
fn full_auth(c: Conn, nonce: bytes, deadline: until, ask: bytes) -> result[bool, str] {
    if c.ssl != nullptr || strings.has_prefix(c.cfg.host, "/") {
        // a Unix socket is as private as TLS
        return send_packet(c, cat([to_bytes(c.cfg.password), b"\x00"]), deadline);
    }
    if c.cfg.server_public_key != "" {
        let kr = read_file(c.cfg.server_public_key);
        guard let pem = kr else let e = err_of(kr) { return err("mysql: server_public_key: " + e); }
        return send_encrypted(c, pem, nonce, deadline);
    }
    if !c.cfg.allow_public_key_retrieval {
        return err("mysql: the server needs the password itself (full caching_sha2_password authentication) and the " +
                   "connection has no TLS; use sslmode=require, set server_public_key=/path/to/key.pem, or " +
                   "allow_public_key_retrieval=true (which trusts whatever key the network sends)");
    }
    return send_packet(c, ask, deadline);
}

fn send_encrypted(c: Conn, pem: str, nonce: bytes, deadline: until) -> result[bool, str] {
    let plain = xor_bytes(cat([to_bytes(c.cfg.password), b"\x00"]), nonce);
    let er = crypto.rsa_encrypt_oaep_sha1(pem, plain);
    guard let ct = er else let e = err_of(er) { return err("mysql: encrypting the password: " + e); }
    return send_packet(c, ct, deadline);
}

fn read_file(path: str) -> result[str, str] {
    let fr = fs.open(path);
    guard let fd = fr else let e = err_of(fr) { return err(e); }
    let parts: [bytes] = [];
    while true {
        let rr = fs.read(fd as int, 65536);
        guard let b = rr else let e = err_of(rr) {
            fs.close(fd as int);
            return err(e);
        }
        if len(b) == 0 {
            break;
        }
        push(parts, b);
    }
    fs.close(fd as int);
    return ok(to_str(cat(parts)));
}
