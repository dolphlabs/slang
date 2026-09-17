import "net";
import "time";
import "strings";
import "crypto";
import "encoding";

// PostgreSQL client, speaking the frontend/backend protocol (version
// 3.0) over `net`.
//
// Written in slang rather than wrapping libpq for the same reason httpc
// is: libpq's calls block the thread they run on, and a slang task that
// blocks a worker thread stalls every other task queued on it. Here a
// query waiting on the server parks its task on the reactor like any
// other socket read, so a server can hold many connections open on a
// handful of threads.
//
// Every fallible call returns result[_, str], exactly like `sql`, and a
// server-side error keeps the server's own text and SQLSTATE:
//
//     ERROR: relation "nope" does not exist (SQLSTATE 42P01)
//
// A Conn is handled by functions taking it first (pg.query(c, ...))
// rather than methods, for the reason httpc gives: a method cannot yet
// share a name with a package function.
//
// WHAT THIS DOES NOT DO, deliberately: no COPY, no LISTEN/NOTIFY
// delivery, no named prepared statements, no binary result format, no
// Unix-domain sockets, no Kerberos/GSSAPI, no SCRAM channel binding
// (SCRAM-SHA-256-PLUS). Results are buffered whole, not streamed.

// ---- limits ----------------------------------------------------------
//
// A driver trusts the server with its memory: every length on the wire
// is the server's to choose. These bound what one bad or hostile server
// (or a man in the middle, over cleartext) can make a program allocate.

let MAX_MESSAGE = 268435456;      // one protocol message, 256 MiB
let MAX_RESULT = 268435456;       // all cells of one result, 256 MiB
let MAX_SCRAM_ITERATIONS = 1000000;
let READ_CHUNK = 65536;
let MAX_READ = 4194304;
let POOL_POLL = 2000000;          // 2ms between checks for a free conn

// ---- types -----------------------------------------------------------

pub gc struct Config {
    host: str,
    port: int,
    user: str,
    password: str,
    database: str,
    // "disable" or "require". "require" VERIFIES the certificate chain
    // and the hostname -- unlike libpq, whose "require" encrypts without
    // checking who is on the other end. See parse_url.
    sslmode: str,
    // A PEM bundle to verify the server against, or "" for the system
    // trust store. Managed Postgres (RDS, Cloud SQL, Supabase) is
    // usually signed by the provider's own CA.
    ca_path: str,
    application_name: str,
    // The TLS context, created on first use and shared by every
    // connection made from this Config -- loading a trust store per
    // connection costs milliseconds.
    tls_ctx: rawptr,
}

gc struct Transport {
    fd: i32,        // the socket; still set after a TLS upgrade
    ssl: rawptr,    // nullptr for cleartext
}

pub gc struct Conn {
    cfg: Config,
    t: Transport,
    buf: bytes,       // received and not yet consumed, from pos
    pos: int,
    // Bumped whenever buf is replaced, so a result holding on to a
    // buffer (see Rows) can tell a new one from the same one.
    gen: int,
    // The message next_msg last read: its type, and where its body sits
    // in buf. Valid until the next read.
    mtyp: int,
    mstart: int,
    mlen: int,
    lock: mutex,
    // Set when the connection can no longer be trusted to be at a
    // message boundary: an I/O error, a timeout, a protocol violation.
    // A broken connection is never used again; `why` says what broke it.
    broken: bool,
    why: str,
    closed: bool,
    // For CancelRequest.
    pid: int,
    secret: int,
    // The ReadyForQuery status: 73 'I' idle, 84 'T' in a transaction,
    // 69 'E' in a failed transaction.
    status: int,
    // ParameterStatus values: server_version, TimeZone, ...
    params: map[str]str,
    in_pool: bool,
}

// A query parameter. Build one with arg_text, arg_int, arg_float,
// arg_bool, arg_bytes or arg_null.
pub gc struct Arg {
    is_null: bool,
    binary: bool,
    data: bytes,
}

// A buffered result. Read cells with get_text / get_int / get_float /
// get_bool / get_bytes, by row and column index; col() finds an index by
// name.
pub gc struct Rows {
    columns: [str],
    types: [int],     // type OIDs, one per column
    count: int,       // number of rows
    // Rows affected, from the command tag: INSERT/UPDATE/DELETE/MERGE
    // report the rows they touched, SELECT the rows it returned.
    affected: int,
    tag: str,         // the command tag itself, e.g. "INSERT 0 3"
    // Cell storage, row-major. Deliberately a handful of heap objects
    // however many cells there are: the collector traces every live
    // object on each cycle, and one `bytes` per cell made a million-row
    // result spend seconds marking. The chunks are the connection's own
    // receive buffers, kept rather than copied from; a cell is a
    // location (chunk * 2^32 + offset) and a length, -1 for NULL.
    chunks: [bytes],
    locs: [int],
    lens: [int],
    chunk_gen: int,       // the Conn.gen of the last chunk
}

// ---- wire encoding ---------------------------------------------------

fn be32(n: int) -> bytes {
    return to_be(n)[4..];
}

fn be16(n: int) -> bytes {
    return to_be(n)[6..];
}

fn byte1(n: int) -> bytes {
    return to_be(n)[7..];
}

fn cstr(s: str) -> bytes {
    return to_bytes(s) + b"\x00";
}

// A typed message: one type byte, then a length that counts itself.
fn msg(typ: int, body: bytes) -> bytes {
    return byte1(typ) + be32(len(body) + 4) + body;
}

fn rd32(b: bytes, at: int) -> int {
    let v = (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
    if v >= 2147483648 {
        v = v - 4294967296;
    }
    return v;
}

fn rd16(b: bytes, at: int) -> int {
    let v = (b[at] << 8) | b[at + 1];
    if v >= 32768 {
        v = v - 65536;
    }
    return v;
}

// Reads fields out of one message body. An overrun sets `bad` instead of
// panicking, so a malformed message from the server becomes an error
// the caller can see rather than a crash of the task.
gc struct Cursor {
    b: bytes,
    i: int,
    bad: bool,
}

fn cur_of(b: bytes) -> Cursor {
    return Cursor { b: b, i: 0, bad: false };
}

fn get8(c: Cursor) -> int {
    if c.i + 1 > len(c.b) {
        c.bad = true;
        return 0;
    }
    c.i = c.i + 1;
    return c.b[c.i - 1];
}

fn get16(c: Cursor) -> int {
    if c.i + 2 > len(c.b) {
        c.bad = true;
        return 0;
    }
    c.i = c.i + 2;
    return rd16(c.b, c.i - 2);
}

fn get32(c: Cursor) -> int {
    if c.i + 4 > len(c.b) {
        c.bad = true;
        return 0;
    }
    c.i = c.i + 4;
    return rd32(c.b, c.i - 4);
}

fn get_n(c: Cursor, n: int) -> bytes {
    if n < 0 || c.i + n > len(c.b) {
        c.bad = true;
        return b"";
    }
    c.i = c.i + n;
    return c.b[c.i - n..c.i];
}

fn get_cstr(c: Cursor) -> str {
    let j = c.i;
    while j < len(c.b) {
        if c.b[j] == 0 {
            let s = to_str(c.b[c.i..j]);
            c.i = j + 1;
            return s;
        }
        j = j + 1;
    }
    c.bad = true;
    return "";
}

// Joins receive chunks pairwise, so assembling a large message costs
// O(n log n) copying rather than the O(n^2) of appending chunk by chunk.
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

// ---- URL -------------------------------------------------------------

fn is_loopback(host: str) -> bool {
    return host == "localhost" || host == "::1" ||
           strings.has_prefix(host, "127.");
}

// postgres://user:password@host:port/database?sslmode=require
//
// Recognised parameters: sslmode, sslrootcert, application_name. Any
// other parameter is an error rather than ignored: a misspelt
// "sslmdoe=require" that was silently dropped would connect in the
// clear, and nothing would ever say so.
//
// sslmode:
//   disable      cleartext.
//   require      TLS, certificate and hostname verified.
//   verify-full  the same as require (the libpq spelling of it).
//   prefer, allow, verify-ca are refused. The first two fall back to
//   cleartext when TLS fails, which is exactly what an attacker in the
//   middle would arrange; verify-ca checks the chain but not the host.
//
// With no sslmode the default is "require" -- except for a loopback
// host, where it is "disable", because traffic that never leaves the
// machine gains nothing from TLS and a local development server almost
// never has it configured.
pub fn parse_url(url: str) -> result[Config, str] {
    let rest = "";
    if strings.has_prefix(url, "postgres://") {
        rest = strings.slice(url, 11, len(url));
    } else if strings.has_prefix(url, "postgresql://") {
        rest = strings.slice(url, 13, len(url));
    } else {
        return err("url must begin with postgres:// or postgresql://");
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
        guard let d = dr else let e = err_of(dr) {
            return err("bad database name in url: " + e);
        }
        database = d;
        authority = strings.slice(rest, 0, slash);
    }

    // The LAST '@': a password may itself contain one, percent-encoded
    // or not.
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
            let pr = encoding.url_decode(strings.slice(userinfo, colon + 1,
                                                       len(userinfo)));
            guard let p = pr else let e = err_of(pr) {
                return err("bad password in url: " + e);
            }
            password = p;
        }
        let ur = encoding.url_decode(raw_user);
        guard let u = ur else let e = err_of(ur) {
            return err("bad user in url: " + e);
        }
        user = u;
    }
    if user == "" {
        return err("url has no user: postgres://user:password@host/database");
    }
    if database == "" {
        database = user;    // the server's own default
    }

    let host = authority;
    let port = 5432;
    if strings.has_prefix(authority, "[") {
        let close = strings.find(authority, "]");
        if close < 0 {
            return err("unterminated IPv6 literal in url");
        }
        host = strings.slice(authority, 1, close);
        let tail = strings.slice(authority, close + 1, len(authority));
        if tail != "" {
            if !strings.has_prefix(tail, ":") {
                return err("junk after IPv6 literal in url");
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
            let pr = to_int(strings.slice(authority, colon + 1, len(authority)));
            guard let p = pr else let e = err_of(pr) {
                return err("bad port in url: " + e);
            }
            port = p;
            host = strings.slice(authority, 0, colon);
        }
    }
    if host == "" {
        return err("url has no host");
    }
    if strings.contains(host, ",") {
        return err("multiple hosts in one url are not supported");
    }
    if port <= 0 || port > 65535 {
        return err("port out of range in url");
    }

    let sslmode = "require";
    if is_loopback(host) {
        sslmode = "disable";
    }
    let ca_path = "";
    let app = "";
    let qurl = "?" + query;
    for k in encoding.query_keys(qurl) {
        let v = encoding.query_get(qurl, k) ?? "";
        if k == "sslmode" {
            if v == "disable" {
                sslmode = "disable";
            } else if v == "require" || v == "verify-full" {
                sslmode = "require";
            } else if v == "prefer" || v == "allow" {
                return err("sslmode=" + v + " is not supported: it falls " +
                           "back to cleartext when TLS fails. Use " +
                           "sslmode=require or sslmode=disable");
            } else if v == "verify-ca" {
                return err("sslmode=verify-ca is not supported: it does " +
                           "not check the hostname. Use sslmode=require, " +
                           "which verifies both");
            } else {
                return err("unknown sslmode: " + v);
            }
        } else if k == "sslrootcert" {
            ca_path = v;
        } else if k == "application_name" {
            app = v;
        } else {
            return err("unsupported url parameter: " + k);
        }
    }

    return ok(Config { host: host, port: port, user: user,
                       password: password, database: database,
                       sslmode: sslmode, ca_path: ca_path,
                       application_name: app, tls_ctx: nullptr });
}

// ---- transport -------------------------------------------------------

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

// Dial, and negotiate TLS in-band if the Config asks for it: an 8-byte
// SSLRequest, one byte back ('S' or 'N'), then the handshake on the same
// socket.
fn open_transport(cfg: Config, deadline: until) -> result[Transport, str] {
    if strings.has_prefix(cfg.host, "/") {
        return err("unix-domain sockets are not supported: " + cfg.host);
    }
    let dr = net.dial(cfg.host, cfg.port);
    guard let fd = dr else let e = err_of(dr) {
        return err("dial " + cfg.host + ": " + e);
    }
    if cfg.sslmode == "disable" {
        return ok(Transport { fd: fd, ssl: nullptr });
    }

    let sr = net.send_until(fd, b"\x00\x00\x00\x08\x04\xd2\x16\x2f", deadline);
    guard let sent = sr else let e = err_of(sr) {
        net.close(fd);
        return err(e);
    }
    // Exactly ONE byte. Anything the server (or a man in the middle)
    // sent after it must stay in the socket, to be read -- and rejected
    // -- by the TLS handshake. Reading more would treat cleartext
    // injected before the handshake as if it had arrived encrypted:
    // CVE-2021-23222.
    let rr = net.recv_until(fd, 1, deadline);
    guard let answer = rr else let e = err_of(rr) {
        net.close(fd);
        return err(e);
    }
    if len(answer) == 0 {
        net.close(fd);
        return err("server closed the connection during TLS negotiation");
    }
    if answer[0] == 78 {    // 'N'
        net.close(fd);
        return err("server " + cfg.host + " does not support TLS; add " +
                   "sslmode=disable to the url to connect without it");
    }
    if answer[0] != 83 {    // 'S'
        net.close(fd);
        return err("unexpected reply to SSLRequest; is this a Postgres server?");
    }

    if cfg.tls_ctx == nullptr {
        let cr = net.tls_client_ctx(cfg.ca_path);
        guard let ctx = cr else let e = err_of(cr) {
            net.close(fd);
            return err("tls context: " + e);
        }
        cfg.tls_ctx = ctx;
    }
    let ur = net.tls_upgrade(fd, cfg.host, cfg.tls_ctx);
    guard let ssl = ur else let e = err_of(ur) {
        net.close(fd);
        let hint = "";
        if strings.contains(e, "certificate verify failed") && cfg.ca_path == "" {
            hint = " (if the server uses its provider's own CA, pass its " +
                   "bundle with sslrootcert=/path/to/ca.pem)";
        }
        return err("tls " + cfg.host + ": " + e + hint);
    }
    return ok(Transport { fd: fd, ssl: ssl });
}

// ---- reading messages ------------------------------------------------

gc struct Msg {
    typ: int,
    body: bytes,
}

// Ensure at least `need` unconsumed bytes are buffered. Returns "" or
// the error. (Not a result: this runs twice per message, and a million-
// row result should not allocate two million results to say "ok".)
fn fill(c: Conn, need: int, deadline: until) -> str {
    let have = len(c.buf) - c.pos;
    if have >= need {
        return "";
    }
    let parts: [bytes] = [];
    if have > 0 {
        push(parts, c.buf[c.pos..]);
    }
    c.buf = b"";
    c.pos = 0;
    c.gen = c.gen + 1;
    while have < need {
        // A large message is read in large pieces: fewer pieces means
        // fewer rounds of joining them. The runtime copies out only what
        // arrived, so asking for more costs nothing when less is there.
        let want = need - have;
        if want < READ_CHUNK {
            want = READ_CHUNK;
        }
        if want > MAX_READ {
            want = MAX_READ;
        }
        let rr = tr_recv(c.t, want, deadline);
        guard let got = rr else let e = err_of(rr) {
            return e;
        }
        if len(got) == 0 {
            return "server closed the connection";
        }
        push(parts, got);
        have = have + len(got);
    }
    c.buf = concat_parts(parts);
    return "";
}

// Reads the next message into c.mtyp / c.mstart / c.mlen without copying
// its body. Returns "" or the error.
fn next_msg(c: Conn, deadline: until) -> str {
    let e = fill(c, 5, deadline);
    if e != "" {
        return e;
    }
    let n = rd32(c.buf, c.pos + 1);
    if n < 4 || n > MAX_MESSAGE {
        return "protocol error: message length " + to_str(n);
    }
    let e2 = fill(c, 1 + n, deadline);
    if e2 != "" {
        return e2;
    }
    c.mtyp = c.buf[c.pos];
    c.mstart = c.pos + 5;
    c.mlen = n - 4;
    c.pos = c.pos + 1 + n;
    return "";
}

fn msg_body(c: Conn) -> bytes {
    return c.buf[c.mstart..c.mstart + c.mlen];
}

fn read_msg(c: Conn, deadline: until) -> result[Msg, str] {
    let e = next_msg(c, deadline);
    if e != "" {
        return err(e);
    }
    return ok(Msg { typ: c.mtyp, body: msg_body(c) });
}

// "ERROR: relation \"nope\" does not exist (SQLSTATE 42P01)"
fn format_error(body: bytes) -> str {
    let cur = cur_of(body);
    let severity = "";
    let localized = "";
    let code = "";
    let message = "";
    while !cur.bad {
        let field = get8(cur);
        if field == 0 {
            break;
        }
        let v = get_cstr(cur);
        if field == 86 {            // 'V': severity, never localized
            severity = v;
        } else if field == 83 {     // 'S': severity, maybe localized
            localized = v;
        } else if field == 67 {     // 'C'
            code = v;
        } else if field == 77 {     // 'M'
            message = v;
        }
    }
    if severity == "" {
        severity = localized;
    }
    if severity == "" {
        severity = "ERROR";
    }
    let s = severity + ": " + message;
    if code != "" {
        s = s + " (SQLSTATE " + code + ")";
    }
    return s;
}

// The SQLSTATE of an error returned by this package, or "" when the
// error did not come from the server (a dial failure, a timeout).
//
//     if pg.sqlstate(e) == "23505" { /* unique_violation */ }
pub fn sqlstate(e: str) -> str {
    let i = strings.rfind(e, "(SQLSTATE ");
    if i < 0 || !strings.has_suffix(e, ")") {
        return "";
    }
    return strings.slice(e, i + 10, len(e) - 1);
}

// Mark the connection unusable. After a timeout the server may still be
// running the query, so it is asked to stop -- from a separate task, on
// a separate connection, as the protocol requires, so the caller gets
// its error now rather than after another dial.
fn break_conn(c: Conn, why: str) {
    if c.broken || c.closed {
        return;
    }
    c.broken = true;
    c.why = why;
    if why == "timeout" && c.pid != 0 {
        spawn send_cancel(c.cfg, c.pid, c.secret);
    }
    tr_close(c.t);
}

fn send_cancel(cfg: Config, pid: int, secret: int) {
    let deadline = until_of(time.mono() + 10000000000);
    let tr = open_transport(cfg, deadline);
    guard let t = tr else {
        return;
    }
    let req = be32(16) + be32(80877102) + be32(pid) + be32(secret);
    tr_send(t, req, deadline);
    // The server closes when it has read the request; wait for that
    // rather than racing it with our own close.
    tr_recv(t, 1, deadline);
    tr_close(t);
}

// ---- authentication --------------------------------------------------

fn startup_message(cfg: Config) -> bytes {
    let body = be32(196608) +                   // protocol 3.0
               cstr("user") + cstr(cfg.user) +
               cstr("database") + cstr(cfg.database) +
               // Text results are decoded as UTF-8 str; make the server
               // send UTF-8 whatever the database's own encoding is.
               cstr("client_encoding") + cstr("UTF8");
    if cfg.application_name != "" {
        body = body + cstr("application_name") + cstr(cfg.application_name);
    }
    body = body + b"\x00";
    return be32(len(body) + 4) + body;
}

fn xor_bytes(a: bytes, b: bytes) -> bytes {
    let out = a[..];
    let i = 0;
    while i < len(out) {
        out[i] = out[i] ^ b[i];
        i = i + 1;
    }
    return out;
}

// One SCRAM-SHA-256 exchange (RFC 5802, RFC 7677), as pure functions of
// its inputs, so the published test vector can check it.
pub gc struct Scram {
    client_final: str,
    server_signature: str,   // base64, what the server must prove
}

pub fn scram_client_final(password: str, client_first_bare: str,
                          server_first: str, client_nonce: str)
                          -> result[Scram, str] {
    let nonce = "";
    let salt_b64 = "";
    let iter_s = "";
    for part in strings.split(server_first, ",") {
        if strings.has_prefix(part, "r=") {
            nonce = strings.slice(part, 2, len(part));
        } else if strings.has_prefix(part, "s=") {
            salt_b64 = strings.slice(part, 2, len(part));
        } else if strings.has_prefix(part, "i=") {
            iter_s = strings.slice(part, 2, len(part));
        } else if strings.has_prefix(part, "m=") {
            return err("SCRAM: server requires an unsupported extension");
        }
    }
    // The server's nonce must EXTEND ours. Otherwise this is a replay of
    // some other exchange.
    if !strings.has_prefix(nonce, client_nonce) || len(nonce) <= len(client_nonce) {
        return err("SCRAM: server nonce does not extend the client nonce");
    }
    let sr = encoding.base64_decode(salt_b64);
    guard let salt = sr else {
        return err("SCRAM: bad salt from server");
    }
    let ir = to_int(iter_s);
    guard let iterations = ir else {
        return err("SCRAM: bad iteration count from server");
    }
    // Chosen by the server, and run on a worker thread that cannot be
    // preempted meanwhile. Postgres uses 4096.
    if iterations < 1 || iterations > MAX_SCRAM_ITERATIONS {
        return err("SCRAM: server asked for " + to_str(iterations) +
                   " iterations; the limit is 1000000");
    }

    let kr = crypto.pbkdf2_sha256(to_bytes(password), salt, iterations, 32);
    guard let salted = kr else let e = err_of(kr) {
        return err("SCRAM: " + e);
    }
    let client_key = crypto.hmac_sha256(salted, b"Client Key");
    let stored_key = crypto.sha256(client_key);
    let without_proof = "c=biws,r=" + nonce;      // biws = base64("n,,")
    let auth_message = client_first_bare + "," + server_first + "," +
                       without_proof;
    let client_sig = crypto.hmac_sha256(stored_key, to_bytes(auth_message));
    let proof = xor_bytes(client_key, client_sig);
    let server_key = crypto.hmac_sha256(salted, b"Server Key");
    let server_sig = crypto.hmac_sha256(server_key, to_bytes(auth_message));
    return ok(Scram {
        client_final: without_proof + ",p=" + encoding.base64_encode(proof),
        server_signature: encoding.base64_encode(server_sig)
    });
}

fn has_mechanism(body: bytes, want: str) -> bool {
    let cur = cur_of(body);
    get32(cur);
    while !cur.bad && cur.i < len(body) {
        let m = get_cstr(cur);
        if m == "" {
            return false;
        }
        if m == want {
            return true;
        }
    }
    return false;
}

fn send_raw(c: Conn, b: bytes, deadline: until) -> result[bool, str] {
    let sr = tr_send(c.t, b, deadline);
    guard let n = sr else let e = err_of(sr) {
        return err(e);
    }
    return ok(true);
}

// Runs the startup exchange to the first ReadyForQuery.
fn handshake(c: Conn, deadline: until) -> result[bool, str] {
    let cfg = c.cfg;
    let sr = send_raw(c, startup_message(cfg), deadline);
    guard let s0 = sr else let e = err_of(sr) {
        return err(e);
    }

    // SCRAM state. An AuthenticationOk before the server has proved it
    // knows the password is refused: otherwise a server (or a man in the
    // middle) could skip the proof and be trusted anyway.
    let scram_started = false;
    let scram_verified = false;
    let client_nonce = "";
    let client_first_bare = "";
    let expect_sig = "";

    while true {
        let mr = read_msg(c, deadline);
        guard let m = mr else let e = err_of(mr) {
            return err(e);
        }
        if m.typ == 69 {            // 'E'
            return err(format_error(m.body));
        }
        if m.typ == 78 {            // 'N' notice
            continue;
        }
        if m.typ == 118 {           // 'v' NegotiateProtocolVersion
            continue;
        }
        if m.typ == 83 {            // 'S' ParameterStatus
            let cur = cur_of(m.body);
            let k = get_cstr(cur);
            let v = get_cstr(cur);
            c.params[k] = v;
            continue;
        }
        if m.typ == 75 {            // 'K' BackendKeyData
            let cur = cur_of(m.body);
            c.pid = get32(cur);
            c.secret = get32(cur);
            continue;
        }
        if m.typ == 90 {            // 'Z' ReadyForQuery
            if len(m.body) < 1 {
                return err("protocol error: empty ReadyForQuery");
            }
            c.status = m.body[0];
            return ok(true);
        }
        if m.typ != 82 {            // 'R'
            return err("protocol error: unexpected message " + to_str(m.typ) +
                       " during startup");
        }

        let cur = cur_of(m.body);
        let code = get32(cur);
        if cur.bad {
            return err("protocol error: short authentication message");
        }
        if code == 0 {              // AuthenticationOk
            if scram_started && !scram_verified {
                return err("SCRAM: server accepted the login without " +
                           "proving it knows the password");
            }
            continue;
        }
        if code == 3 || code == 5 {
            if cfg.password == "" {
                return err("server requires a password and the url has none");
            }
            let answer = cfg.password;
            if code == 5 {          // md5(md5(password + user) + salt)
                let salt = get_n(cur, 4);
                if cur.bad {
                    return err("protocol error: short md5 salt");
                }
                let inner = encoding.hex_encode(crypto.md5(to_bytes(cfg.password + cfg.user)));
                answer = "md5" + encoding.hex_encode(crypto.md5(to_bytes(inner) + salt));
            }
            let pr = send_raw(c, msg(112, cstr(answer)), deadline);
            guard let p = pr else let e = err_of(pr) {
                return err(e);
            }
            continue;
        }
        if code == 10 {             // AuthenticationSASL
            if !has_mechanism(m.body, "SCRAM-SHA-256") {
                return err("server offers no SASL mechanism this driver " +
                           "supports (SCRAM-SHA-256)");
            }
            if cfg.password == "" {
                return err("server requires a password and the url has none");
            }
            let nr = crypto.rand(18);
            guard let nb = nr else let e = err_of(nr) {
                return err("SCRAM nonce: " + e);
            }
            client_nonce = encoding.base64_encode(nb);
            // Postgres ignores the SCRAM user name -- it already has the
            // one from the startup message -- and libpq sends it empty.
            client_first_bare = "n=,r=" + client_nonce;
            let first = "n,," + client_first_bare;
            let body = cstr("SCRAM-SHA-256") + be32(len(first)) + to_bytes(first);
            let pr = send_raw(c, msg(112, body), deadline);
            guard let p = pr else let e = err_of(pr) {
                return err(e);
            }
            scram_started = true;
            continue;
        }
        if code == 11 {             // AuthenticationSASLContinue
            if !scram_started || expect_sig != "" {
                return err("protocol error: unexpected SASLContinue");
            }
            let server_first = to_str(m.body[4..]);
            let xr = scram_client_final(cfg.password, client_first_bare,
                                        server_first, client_nonce);
            guard let x = xr else let e = err_of(xr) {
                return err(e);
            }
            expect_sig = x.server_signature;
            let pr = send_raw(c, msg(112, to_bytes(x.client_final)), deadline);
            guard let p = pr else let e = err_of(pr) {
                return err(e);
            }
            continue;
        }
        if code == 12 {             // AuthenticationSASLFinal
            if expect_sig == "" {
                return err("protocol error: unexpected SASLFinal");
            }
            let server_final = to_str(m.body[4..]);
            if server_final != "v=" + expect_sig {
                return err("SCRAM: the server's signature is wrong; it does " +
                           "not know the password");
            }
            scram_verified = true;
            continue;
        }
        return err("unsupported authentication method (code " + to_str(code) +
                   "); supported are SCRAM-SHA-256, md5 and password");
    }
    return err("unreachable");
}

// ---- connecting ------------------------------------------------------

pub fn connect(url: str, deadline: until) -> result[Conn, str] {
    let cr = parse_url(url);
    guard let cfg = cr else let e = err_of(cr) {
        return err(e);
    }
    return connect_config(cfg, deadline);
}

// The deadline bounds the startup and authentication exchange. It does
// not bound the TCP connect or the TLS handshake themselves, which
// net.dial and net.tls_upgrade do not yet take one for.
pub fn connect_config(cfg: Config, deadline: until) -> result[Conn, str] {
    let tr = open_transport(cfg, deadline);
    guard let t = tr else let e = err_of(tr) {
        return err(e);
    }
    let params: map[str]str = {};
    let c = Conn { cfg: cfg, t: t, buf: b"", pos: 0, gen: 0, mtyp: 0,
                   mstart: 0, mlen: 0, lock: make_mutex(),
                   broken: false, why: "", closed: false, pid: 0, secret: 0,
                   status: 0, params: params, in_pool: false };
    let hr = handshake(c, deadline);
    guard let h = hr else let e = err_of(hr) {
        tr_close(t);
        return err(e);
    }
    return ok(c);
}

// Ends the session politely (Terminate) and closes the socket. Safe to
// call on a broken or already-closed connection.
pub fn close(c: Conn) {
    mutex_lock(c.lock);
    if !c.closed && !c.broken {
        tr_send(c.t, msg(88, b""), until_of(time.mono() + 1000000000));
        tr_close(c.t);
    }
    c.closed = true;
    mutex_unlock(c.lock);
}

// Is the connection still usable? False once it has been closed or has
// broken; a false Conn only ever returns errors.
pub fn usable(c: Conn) -> bool {
    return !c.closed && !c.broken;
}

// Inside a transaction block (including a failed one that still needs
// ROLLBACK)?
pub fn in_transaction(c: Conn) -> bool {
    return c.status == 84 || c.status == 69;
}

// A server setting reported at startup or after SET: "server_version",
// "TimeZone", "standard_conforming_strings", ...
pub fn server_param(c: Conn, name: str) -> opt[str] {
    if has(c.params, name) {
        return some(c.params[name]);
    }
    return none;
}

fn check_usable(c: Conn, deadline: until) -> result[bool, str] {
    if c.closed {
        return err("connection is closed");
    }
    if c.broken {
        return err("connection is broken: " + c.why);
    }
    // Checked before a byte is written: a deadline that has already
    // passed should fail the call, not break a healthy connection.
    if until_hit(deadline) {
        return err("timeout");
    }
    return ok(true);
}

// ---- query parameters ------------------------------------------------

pub fn arg_text(s: str) -> Arg {
    return Arg { is_null: false, binary: false, data: to_bytes(s) };
}

pub fn arg_int(n: int) -> Arg {
    return Arg { is_null: false, binary: false, data: to_bytes(to_str(n)) };
}

// Sent as the shortest text that reads back as exactly this float:
// to_str's six significant digits would round it.
pub fn arg_float(x: float) -> Arg {
    return Arg { is_null: false, binary: false,
                 data: to_bytes(strings.from_float(x)) };
}

pub fn arg_bool(b: bool) -> Arg {
    let s = "false";
    if b {
        s = "true";
    }
    return Arg { is_null: false, binary: false, data: to_bytes(s) };
}

// Sent in binary, so any byte values -- NULs included -- arrive intact.
// For a bytea column.
pub fn arg_bytes(b: bytes) -> Arg {
    return Arg { is_null: false, binary: true, data: b };
}

pub fn arg_null() -> Arg {
    return Arg { is_null: true, binary: false, data: b"" };
}

// The argument list of a query with no parameters. A bare [] cannot be
// passed yet: an empty list literal needs a declared type, and the
// compiler does not take it from the parameter.
pub fn no_args() -> [Arg] {
    let none_args: [Arg] = [];
    return none_args;
}

// ---- running queries -------------------------------------------------

// Rows affected, from a command tag: the last word when it is a number.
// "INSERT 0 3" -> 3, "UPDATE 2" -> 2, "CREATE TABLE" -> 0.
fn tag_count(tag: str) -> int {
    let sp = strings.rfind(tag, " ");
    if sp < 0 {
        return 0;
    }
    return to_int(strings.slice(tag, sp + 1, len(tag))) ?? 0;
}

fn empty_rows() -> Rows {
    let cols: [str] = [];
    let types: [int] = [];
    let chunks: [bytes] = [];
    let locs: [int] = [];
    let lens: [int] = [];
    return Rows { columns: cols, types: types, count: 0, affected: 0,
                  tag: "", chunks: chunks, locs: locs, lens: lens,
                  chunk_gen: -1 };
}

// Records the DataRow next_msg just read, in place. Returns "" or what
// was wrong with it.
fn add_row(rows: Rows, c: Conn) -> str {
    let b = c.buf;
    let i = c.mstart;
    let end = c.mstart + c.mlen;
    let ncols = len(rows.columns);
    if c.mlen < 2 {
        return "protocol error: malformed DataRow";
    }
    let n = rd16(b, i);
    if n != ncols {
        return "protocol error: row has " + to_str(n) + " fields, expected " +
               to_str(ncols);
    }
    if rows.chunk_gen != c.gen {
        push(rows.chunks, b);
        rows.chunk_gen = c.gen;
    }
    let base = (len(rows.chunks) - 1) * 4294967296;
    i = i + 2;
    let k = 0;
    while k < n {
        if i + 4 > end {
            return "protocol error: malformed DataRow";
        }
        let flen = rd32(b, i);
        i = i + 4;
        if flen == -1 {
            push(rows.locs, 0);
            push(rows.lens, -1);
        } else {
            if flen < 0 || i + flen > end {
                return "protocol error: malformed DataRow";
            }
            push(rows.locs, base + i);
            push(rows.lens, flen);
            i = i + flen;
        }
        k = k + 1;
    }
    if i != end {
        return "protocol error: malformed DataRow";
    }
    rows.count = rows.count + 1;
    return "";
}

// Reads responses up to ReadyForQuery. `rows` collects the result;
// `synced` says whether a Sync was sent (extended protocol), which
// changes how a COPY FROM STDIN has to be refused.
fn collect(c: Conn, rows: Rows, synced: bool, deadline: until)
           -> result[bool, str] {
    let server_err = "";
    let size = 0;
    while true {
        let ne = next_msg(c, deadline);
        if ne != "" {
            return err(ne);
        }
        let t = c.mtyp;
        if t == 68 {                // 'D' DataRow: the hot path, no copy
            let bad = add_row(rows, c);
            if bad != "" {
                return err(bad);
            }
            size = size + c.mlen;
            if size > MAX_RESULT {
                return err("result exceeds the 256 MiB limit");
            }
            continue;
        }
        let body = msg_body(c);
        if t == 84 {         // 'T' RowDescription
            let cur = cur_of(body);
            let n = get16(cur);
            let cols: [str] = [];
            let types: [int] = [];
            let k = 0;
            while k < n && !cur.bad {
                push(cols, get_cstr(cur));
                get32(cur);         // table OID
                get16(cur);         // column attribute number
                push(types, get32(cur));
                get16(cur);         // type size
                get32(cur);         // type modifier
                get16(cur);         // format code
                k = k + 1;
            }
            if cur.bad {
                return err("protocol error: malformed RowDescription");
            }
            // With several statements (exec) each result replaces the
            // last; only the final one is kept.
            rows.columns = cols;
            rows.types = types;
            let fresh = empty_rows();
            rows.count = 0;
            rows.chunks = fresh.chunks;
            rows.locs = fresh.locs;
            rows.lens = fresh.lens;
            rows.chunk_gen = -1;
        } else if t == 67 {         // 'C' CommandComplete
            let cur = cur_of(body);
            rows.tag = get_cstr(cur);
            rows.affected = tag_count(rows.tag);
        } else if t == 69 {         // 'E' ErrorResponse
            if server_err == "" {
                server_err = format_error(body);
            }
        } else if t == 90 {         // 'Z' ReadyForQuery
            if len(body) < 1 {
                return err("protocol error: empty ReadyForQuery");
            }
            c.status = body[0];
            if server_err != "" {
                return err(server_err);
            }
            return ok(true);
        } else if t == 71 {         // 'G' CopyInResponse
            // The server now wants data this API has no way to supply.
            // CopyFail ends the COPY with an error; after an extended-
            // protocol query the server ignored our earlier Sync while
            // in copy mode, so it needs another.
            let out = msg(102, cstr("COPY FROM STDIN is not supported by pg"));
            if synced {
                out = out + msg(83, b"");
            }
            let sr = send_raw(c, out, deadline);
            guard let s = sr else let e = err_of(sr) {
                return err(e);
            }
        } else if t == 83 {         // 'S' ParameterStatus, after SET
            let cur = cur_of(body);
            let k = get_cstr(cur);
            let v = get_cstr(cur);
            c.params[k] = v;
        } else if t == 49 || t == 50 || t == 110 || t == 73 || t == 78 ||
                  t == 65 || t == 72 || t == 100 || t == 99 || t == 116 {
            // '1' ParseComplete, '2' BindComplete, 'n' NoData,
            // 'I' EmptyQueryResponse, 'N' notice, 'A' notification,
            // 'H' CopyOutResponse, 'd' CopyData, 'c' CopyDone,
            // 't' ParameterDescription: nothing to keep.
        } else {
            return err("protocol error: unexpected message " + to_str(t));
        }
    }
    return err("unreachable");
}

fn send_and_collect(c: Conn, out: bytes, rows: Rows, synced: bool,
                    deadline: until) -> result[bool, str] {
    let sr = send_raw(c, out, deadline);
    guard let sent = sr else let e = err_of(sr) {
        return err(e);
    }
    return collect(c, rows, synced, deadline);
}

// A failure while a query is on the wire leaves the stream at an unknown
// offset, so the connection is broken rather than reused. A server-side
// error is not such a failure: its ReadyForQuery has been read, the
// stream is back at a boundary and the connection is fine.
fn finish(c: Conn, r: result[bool, str]) -> result[bool, str] {
    guard let v = r else let e = err_of(r) {
        if c.status == 0 {      // no ReadyForQuery: mid-stream
            break_conn(c, e);
        }
        return err(e);
    }
    return ok(v);
}

// Runs one query with parameters ($1, $2, ...) through the extended
// protocol: the values travel separately from the SQL text, so they can
// never be parsed as SQL. Returns every row, buffered.
pub fn query(c: Conn, sql: str, args: [Arg], deadline: until)
             -> result[Rows, str] {
    mutex_lock(c.lock);
    let ur = check_usable(c, deadline);
    guard let u = ur else let e = err_of(ur) {
        mutex_unlock(c.lock);
        return err(e);
    }
    if len(args) > 65535 {
        mutex_unlock(c.lock);
        return err("too many parameters: " + to_str(len(args)) +
                   " (the protocol allows 65535)");
    }

    let formats = be16(len(args));
    let values = be16(len(args));
    for a in args {
        if a.binary {
            formats = formats + be16(1);
        } else {
            formats = formats + be16(0);
        }
        if a.is_null {
            values = values + be32(-1);
        } else {
            values = values + be32(len(a.data)) + a.data;
        }
    }
    let out = msg(80, cstr("") + cstr(sql) + be16(0)) +            // Parse
              msg(66, cstr("") + cstr("") + formats + values +     // Bind
                  be16(0)) +                                       //   text results
              msg(68, b"P" + cstr("")) +                           // Describe portal
              msg(69, cstr("") + be32(0)) +                        // Execute, all rows
              msg(83, b"");                                        // Sync

    // Status 0 marks "no ReadyForQuery read yet", which finish() uses to
    // tell a clean server error from a stream left mid-message.
    let before = c.status;
    c.status = 0;
    let rows = empty_rows();
    let fr = finish(c, send_and_collect(c, out, rows, true, deadline));
    if c.status == 0 {
        c.status = before;
    }
    mutex_unlock(c.lock);
    guard let f = fr else let e = err_of(fr) {
        return err(e);
    }
    return ok(rows);
}

// Runs SQL with no parameters through the simple protocol, which accepts
// several statements separated by semicolons -- a migration, a schema.
// Returns the rows affected by the last statement. Rows a statement
// returns are read and discarded.
//
// Never build `sql` from untrusted input: use query() and parameters.
pub fn exec(c: Conn, sql: str, deadline: until) -> result[int, str] {
    mutex_lock(c.lock);
    let ur = check_usable(c, deadline);
    guard let u = ur else let e = err_of(ur) {
        mutex_unlock(c.lock);
        return err(e);
    }
    let before = c.status;
    c.status = 0;
    let rows = empty_rows();
    let fr = finish(c, send_and_collect(c, msg(81, cstr(sql)), rows, false,
                                        deadline));
    if c.status == 0 {
        c.status = before;
    }
    mutex_unlock(c.lock);
    guard let f = fr else let e = err_of(fr) {
        return err(e);
    }
    return ok(rows.affected);
}

// ---- reading results -------------------------------------------------

fn type_name(oid: int) -> str {
    if oid == 16 { return "bool"; }
    if oid == 17 { return "bytea"; }
    if oid == 20 { return "int8"; }
    if oid == 21 { return "int2"; }
    if oid == 23 { return "int4"; }
    if oid == 25 { return "text"; }
    if oid == 26 { return "oid"; }
    if oid == 114 { return "json"; }
    if oid == 700 { return "float4"; }
    if oid == 701 { return "float8"; }
    if oid == 1042 { return "char"; }
    if oid == 1043 { return "varchar"; }
    if oid == 1082 { return "date"; }
    if oid == 1114 { return "timestamp"; }
    if oid == 1184 { return "timestamptz"; }
    if oid == 1700 { return "numeric"; }
    if oid == 2950 { return "uuid"; }
    if oid == 3802 { return "jsonb"; }
    return "type " + to_str(oid);
}

// The index of the column called `name`. Panics if there is none: the
// query and the code reading it disagree, which is a bug, not a
// condition to handle.
pub fn col(rows: Rows, name: str) -> int {
    let i = 0;
    while i < len(rows.columns) {
        if rows.columns[i] == name {
            return i;
        }
        i = i + 1;
    }
    panic("no column named '" + name + "' (columns: " +
          strings.join(rows.columns, ", ") + ")");
}

fn cell_index(rows: Rows, r: int, c: int) -> int {
    let n = len(rows.columns);
    if r < 0 || r >= rows.count {
        panic("row " + to_str(r) + " out of range (" + to_str(rows.count) +
              " rows)");
    }
    if c < 0 || c >= n {
        panic("column " + to_str(c) + " out of range (" + to_str(n) +
              " columns)");
    }
    return r * n + c;
}

pub fn is_null(rows: Rows, r: int, c: int) -> bool {
    return rows.lens[cell_index(rows, r, c)] == -1;
}

// The cell, which must not be NULL. The getters panic on NULL rather
// than inventing a 0 or "": a NULL the code did not expect is a bug to
// see, and a nullable column is checked with is_null first.
fn cell(rows: Rows, r: int, c: int, want: str) -> bytes {
    let i = cell_index(rows, r, c);
    let n = rows.lens[i];
    if n == -1 {
        panic("column '" + rows.columns[c] + "' is NULL in row " + to_str(r) +
              "; check pg.is_null before pg.get_" + want);
    }
    let loc = rows.locs[i];
    let off = loc & 4294967295;
    return rows.chunks[loc >> 32][off..off + n];
}

fn wrong_type(rows: Rows, c: int, want: str) {
    panic("column '" + rows.columns[c] + "' is " + type_name(rows.types[c]) +
          ", which pg.get_" + want + " does not read");
}

// Any column, in Postgres's text form: numbers, dates, uuid and json
// all arrive this way.
pub fn get_text(rows: Rows, r: int, c: int) -> str {
    return to_str(cell(rows, r, c, "text"));
}

// int2, int4, int8 and oid.
pub fn get_int(rows: Rows, r: int, c: int) -> int {
    cell_index(rows, r, c);
    let oid = rows.types[c];
    if oid != 20 && oid != 21 && oid != 23 && oid != 26 {
        wrong_type(rows, c, "int");
    }
    let s = to_str(cell(rows, r, c, "int"));
    let ir = to_int(s);
    guard let v = ir else let e = err_of(ir) {
        panic("column '" + rows.columns[c] + "': " + e);
    }
    return v;
}

// float4, float8, numeric, and the integer types. A numeric too precise
// for a double is rounded; read it with get_text to keep every digit.
pub fn get_float(rows: Rows, r: int, c: int) -> float {
    cell_index(rows, r, c);
    let oid = rows.types[c];
    if oid != 700 && oid != 701 && oid != 1700 && oid != 20 && oid != 21 &&
       oid != 23 {
        wrong_type(rows, c, "float");
    }
    let s = to_str(cell(rows, r, c, "float"));
    if s == "NaN" || s == "Infinity" || s == "-Infinity" {
        panic("column '" + rows.columns[c] + "' is " + s +
              ", which slang floats written as text cannot carry; use get_text");
    }
    let fr = to_float(s);
    guard let v = fr else let e = err_of(fr) {
        panic("column '" + rows.columns[c] + "': " + e);
    }
    return v;
}

pub fn get_bool(rows: Rows, r: int, c: int) -> bool {
    cell_index(rows, r, c);
    if rows.types[c] != 16 {
        wrong_type(rows, c, "bool");
    }
    return to_str(cell(rows, r, c, "bool")) == "t";
}

// bytea, decoded from the server's hex output format.
pub fn get_bytes(rows: Rows, r: int, c: int) -> bytes {
    cell_index(rows, r, c);
    if rows.types[c] != 17 {
        wrong_type(rows, c, "bytes");
    }
    let raw = cell(rows, r, c, "bytes");
    if len(raw) < 2 || raw[0] != 92 || raw[1] != 120 {     // "\x"
        panic("column '" + rows.columns[c] + "': bytea is not in hex " +
              "format; set bytea_output = 'hex'");
    }
    let hr = encoding.hex_decode(to_str(raw[2..]));
    guard let b = hr else let e = err_of(hr) {
        panic("column '" + rows.columns[c] + "': " + e);
    }
    return b;
}

// ---- pool ------------------------------------------------------------

gc struct Idle {
    c: Conn,
    since: duration,
}

// A bounded set of connections to one database, shared by any number of
// tasks.
pub gc struct Pool {
    cfg: Config,
    // Connections open at once, idle and in use together. A task that
    // needs one when all are in use waits for a release.
    max_open: int,
    // Nanoseconds a connection may sit idle before it is closed instead
    // of reused. Default 5 minutes.
    idle_timeout: int,
    idle: [Idle],
    open: int,
    lock: mutex,
    closed: bool,
    // Connections dialled, and acquisitions served by an idle one.
    dials: int,
    reuses: int,
}

// Parses the url; connects nothing until the first acquire.
pub fn new_pool(url: str, max_open: int) -> result[Pool, str] {
    let cr = parse_url(url);
    guard let cfg = cr else let e = err_of(cr) {
        return err(e);
    }
    if max_open < 1 {
        return err("max_open must be at least 1");
    }
    let idle: [Idle] = [];
    return ok(Pool { cfg: cfg, max_open: max_open, idle_timeout: 300000000000,
                     idle: idle, open: 0, lock: make_mutex(), closed: false,
                     dials: 0, reuses: 0 });
}

// A connection for the caller's exclusive use, until release(). Prefer
// pool_query / pool_exec, which cannot forget to release; acquire is for
// a transaction, which needs several statements on one connection.
pub fn acquire(p: Pool, deadline: until) -> result[Conn, str] {
    while true {
        mutex_lock(p.lock);
        if p.closed {
            mutex_unlock(p.lock);
            return err("pool is closed");
        }
        let now = time.mono();
        while len(p.idle) > 0 {
            let it = p.idle[len(p.idle) - 1];
            p.idle = p.idle[..len(p.idle) - 1];
            // Probed before reuse: the server closes idle sessions on
            // timers of its own (idle_session_timeout, a proxy's), and a
            // query written onto a closed connection fails in a way that
            // cannot be told from the query itself failing.
            let alive = net.idle_alive(it.c.t.fd);
            if it.c.t.ssl != nullptr {
                alive = net.tls_idle_alive(it.c.t.ssl);
            }
            if now - it.since > p.idle_timeout || !alive || !usable(it.c) {
                p.open = p.open - 1;
                close(it.c);
                continue;
            }
            p.reuses = p.reuses + 1;
            it.c.in_pool = false;
            mutex_unlock(p.lock);
            return ok(it.c);
        }
        if p.open < p.max_open {
            p.open = p.open + 1;
            p.dials = p.dials + 1;
            mutex_unlock(p.lock);
            let cr = connect_config(p.cfg, deadline);
            guard let c = cr else let e = err_of(cr) {
                mutex_lock(p.lock);
                p.open = p.open - 1;
                mutex_unlock(p.lock);
                return err(e);
            }
            return ok(c);
        }
        mutex_unlock(p.lock);
        if until_hit(deadline) {
            return err("timeout");
        }
        time.sleep(POOL_POLL);
    }
    return err("unreachable");
}

// Returns a connection to the pool. One that is broken, closed, or still
// inside a transaction is closed instead: handing an open transaction to
// the next caller would run its statements inside someone else's
// uncommitted work.
pub fn release(p: Pool, c: Conn) {
    if c.in_pool {
        panic("pg.release: connection released twice");
    }
    let reusable = usable(c) && c.status == 73;
    mutex_lock(p.lock);
    if p.closed || !reusable {
        p.open = p.open - 1;
        mutex_unlock(p.lock);
        close(c);
        return;
    }
    c.in_pool = true;
    push(p.idle, Idle { c: c, since: time.mono() });
    mutex_unlock(p.lock);
}

pub fn pool_query(p: Pool, sql: str, args: [Arg], deadline: until)
                  -> result[Rows, str] {
    let ar = acquire(p, deadline);
    guard let c = ar else let e = err_of(ar) {
        return err(e);
    }
    let r = query(c, sql, args, deadline);
    release(p, c);
    return r;
}

pub fn pool_exec(p: Pool, sql: str, deadline: until) -> result[int, str] {
    let ar = acquire(p, deadline);
    guard let c = ar else let e = err_of(ar) {
        return err(e);
    }
    let r = exec(c, sql, deadline);
    release(p, c);
    return r;
}

// Closes every idle connection. Connections in use are closed as they
// are released; acquire fails from now on.
pub fn pool_close(p: Pool) {
    mutex_lock(p.lock);
    p.closed = true;
    for it in p.idle {
        p.open = p.open - 1;
        close(it.c);
    }
    let none_idle: [Idle] = [];
    p.idle = none_idle;
    mutex_unlock(p.lock);
}
