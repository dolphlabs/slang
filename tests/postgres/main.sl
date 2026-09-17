import "pg";
import "net";
import "time";
import "crypto";
import "encoding";
import "strings";

// The pg driver against scripted fake servers: every behaviour a real
// Postgres would not volunteer -- a lying SCRAM server, a malformed
// row, a connection dropped mid-result, a query that never answers.
// Runs anywhere, with no database. tests/live/postgres covers a real server.

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn soon() -> until {
    return until_of(time.mono() + 5000000000);
}

// ---- the fake server's side of the wire ------------------------------

fn be32(n: int) -> bytes {
    return to_be(n)[4..];
}

fn be16(n: int) -> bytes {
    return to_be(n)[6..];
}

fn cstr(s: str) -> bytes {
    return to_bytes(s) + b"\x00";
}

fn msg(typ: int, body: bytes) -> bytes {
    return to_be(typ)[7..] + be32(len(body) + 4) + body;
}

fn rd32(b: bytes, at: int) -> int {
    return (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
}

gc struct Peer {
    fd: i32,
    buf: bytes,
}

gc struct Got {
    typ: int,
    body: bytes,
}

fn need(p: Peer, n: int) -> bool {
    while len(p.buf) < n {
        let rr = net.recv_until(p.fd, 65536, soon());
        guard let b = rr else {
            return false;
        }
        if len(b) == 0 {
            return false;
        }
        p.buf = p.buf + b;
    }
    return true;
}

// A typed client message; typ -1 when the client went away.
fn next(p: Peer) -> Got {
    if !need(p, 5) {
        return Got { typ: -1, body: b"" };
    }
    let n = rd32(p.buf, 1);
    if !need(p, 1 + n) {
        return Got { typ: -1, body: b"" };
    }
    let g = Got { typ: p.buf[0], body: p.buf[5..1 + n] };
    p.buf = p.buf[1 + n..];
    return g;
}

// The untyped startup packet (or SSLRequest / CancelRequest).
fn startup(p: Peer) -> bytes {
    if !need(p, 4) {
        return b"";
    }
    let n = rd32(p.buf, 0);
    if !need(p, n) {
        return b"";
    }
    let b = p.buf[..n];
    p.buf = p.buf[n..];
    return b;
}

fn accept_peer(lfd: i32) -> Peer {
    let ar = net.accept(lfd);
    guard let fd = ar else {
        die("accept");
        return Peer { fd: -1, buf: b"" };
    }
    return Peer { fd: fd, buf: b"" };
}

fn send(p: Peer, b: bytes) {
    net.send(p.fd, b);
}

fn auth_ok() -> bytes {
    return msg(82, be32(0));
}

fn ready(status: int) -> bytes {
    return msg(90, to_be(status)[7..]);
}

fn hello() -> bytes {
    return auth_ok() +
           msg(83, cstr("server_version") + cstr("16.0 fake")) +
           msg(75, be32(4242) + be32(777)) +
           ready(73);
}

// Read client messages through Sync (extended protocol) or the single
// Query message (simple protocol). Returns the first message's type.
fn drain_query(p: Peer) -> int {
    let first = -1;
    while true {
        let g = next(p);
        if first == -1 {
            first = g.typ;
        }
        if g.typ == -1 || g.typ == 83 || g.typ == 81 {
            return first;
        }
    }
    return first;
}

fn row_desc(names: [str], oids: [int]) -> bytes {
    let body = be16(len(names));
    let i = 0;
    while i < len(names) {
        body = body + cstr(names[i]) + be32(0) + be16(0) + be32(oids[i]) +
               be16(-1) + be32(-1) + be16(0);
        i = i + 1;
    }
    return msg(84, body);
}

fn error_msg(code: str, text: str) -> bytes {
    return msg(69, b"S" + cstr("ERROR") + b"V" + cstr("ERROR") + b"C" +
               cstr(code) + b"M" + cstr(text) + b"\x00");
}

fn listener() -> i32 {
    let lr = net.listen(0);
    guard let lfd = lr else {
        die("listen");
        return -1 as i32;
    }
    return lfd;
}

fn url_for(lfd: i32, userinfo: str) -> str {
    let pr = net.port(lfd);
    guard let port = pr else {
        die("port");
        return "";
    }
    return "postgres://" + userinfo + "@127.0.0.1:" + to_str(port) + "/d";
}

fn must_connect(url: str) -> pg.Conn {
    let cr = pg.connect(url, soon());
    guard let c = cr else let e = err_of(cr) {
        die("connect: " + e);
        panic("unreachable");
    }
    return c;
}

fn connect_error(url: str) -> str {
    let cr = pg.connect(url, soon());
    guard let c = cr else let e = err_of(cr) {
        return e;
    }
    die("connect should have failed: " + url);
    return "";
}

// ---- scenario: trust login, a query, parameters on the wire ----------

fn srv_query(lfd: i32, seen: chan[bytes]) {
    let p = accept_peer(lfd);
    startup(p);
    send(p, hello());
    // Capture the Bind message to check how parameters were encoded.
    let bind = b"";
    while true {
        let g = next(p);
        if g.typ == 66 {
            bind = g.body;
        }
        if g.typ == 83 || g.typ == -1 {
            break;
        }
    }
    chan_send(seen, bind);
    send(p, msg(49, b"") + msg(50, b"") +
            row_desc(["id", "name", "score", "ok", "data"], [20, 25, 701, 16, 17]) +
            msg(68, be16(5) + be32(2) + b"42" + be32(3) + b"zo\x65" +
                be32(19) + b"0.30000000000000004" + be32(1) + b"t" +
                be32(6) + b"\\x00ff") +
            msg(68, be16(5) + be32(2) + b"-7" + be32(-1) + be32(1) + b"2" +
                be32(1) + b"f" + be32(-1)) +
            msg(67, cstr("SELECT 2")) + ready(73));
    next(p);    // Terminate
    net.close(p.fd);
}

fn scenario_query() {
    let lfd = listener();
    let seen: chan[bytes] = make_chan(1);
    spawn srv_query(lfd, seen);
    let c = must_connect(url_for(lfd, "u"));
    if (pg.server_param(c, "server_version") ?? "") != "16.0 fake" {
        die("server_param");
    }
    let qr = pg.query(c, "SELECT $1, $2, $3", [pg.arg_int(5), pg.arg_null(),
                      pg.arg_bytes(b"\x00\x01")], soon());
    guard let rows = qr else let e = err_of(qr) {
        die("query: " + e);
        return;
    }
    // Bind: portal "", statement "", 3 format codes (0 text, 0 text,
    // 1 binary), 3 values: "5", NULL (-1), two raw bytes. Then 0 result
    // format codes.
    let want = b"\x00\x00" + be16(3) + be16(0) + be16(0) + be16(1) + be16(3) +
               be32(1) + b"5" + be32(-1) + be32(2) + b"\x00\x01" + be16(0);
    let bind = chan_recv(seen) ?? b"";
    if bind != want {
        die("Bind encoding: " + encoding.hex_encode(bind));
    }
    if rows.count != 2 || rows.affected != 2 || rows.tag != "SELECT 2" {
        die("rows meta");
    }
    if pg.get_int(rows, 0, 0) != 42 || pg.get_text(rows, 0, 1) != "zoe" {
        die("row 0 id/name");
    }
    if pg.get_float(rows, 0, 2) != 0.1 + 0.2 || !pg.get_bool(rows, 0, 3) {
        die("row 0 score/ok");
    }
    if pg.get_bytes(rows, 0, 4) != b"\x00\xff" {
        die("row 0 bytea");
    }
    if pg.get_int(rows, 1, pg.col(rows, "id")) != -7 || !pg.is_null(rows, 1, 1) ||
       pg.get_float(rows, 1, 2) != 2.0 || pg.get_bool(rows, 1, 3) ||
       !pg.is_null(rows, 1, 4) {
        die("row 1");
    }
    pg.close(c);
    if pg.usable(c) {
        die("usable after close");
    }
    let after = pg.query(c, "SELECT 1", pg.no_args(), soon());
    guard let x = after else let e = err_of(after) {
        if e != "connection is closed" {
            die("query after close: " + e);
        }
        println("ok query");
        return;
    }
    die("query after close succeeded");
}

// ---- scenario: md5 and cleartext passwords ----------------------------

fn srv_md5(lfd: i32, seen: chan[str]) {
    let p = accept_peer(lfd);
    startup(p);
    send(p, msg(82, be32(5) + b"abcd"));
    let g = next(p);
    chan_send(seen, to_str(g.body[..len(g.body) - 1]));
    send(p, hello());
    next(p);
    net.close(p.fd);
}

fn srv_password(lfd: i32) {
    let p = accept_peer(lfd);
    startup(p);
    send(p, msg(82, be32(3)));
    next(p);
    net.close(p.fd);
}

fn scenario_passwords() {
    let lfd = listener();
    let seen: chan[str] = make_chan(1);
    spawn srv_md5(lfd, seen);
    let c = must_connect(url_for(lfd, "u:p"));
    // md5(md5("p" + "u") + "abcd"), computed independently in Python
    let got = chan_recv(seen) ?? "";
    if got != "md5fa55bd30a96b8d5bd8215eee7c50a918" {
        die("md5 answer: " + got);
    }
    pg.close(c);

    let lfd2 = listener();
    spawn srv_password(lfd2);
    let e = connect_error(url_for(lfd2, "u"));
    if !strings.contains(e, "requires a password and the url has none") {
        die("no password: " + e);
    }
    println("ok passwords");
}

// ---- scenario: SCRAM, honest and dishonest servers --------------------
//
// mode 0: honest. 1: wrong server signature. 2: skips SASLFinal and
// sends AuthenticationOk. 3: AuthenticationOk straight after offering
// SCRAM. 4: offers only a mechanism the driver lacks.

fn srv_scram(lfd: i32, mode: int, verdict: chan[str]) {
    let p = accept_peer(lfd);
    startup(p);
    if mode == 4 {
        send(p, msg(82, be32(10) + cstr("SCRAM-SHA-256-PLUS") + b"\x00"));
        next(p);
        net.close(p.fd);
        chan_send(verdict, "n/a");
        return;
    }
    send(p, msg(82, be32(10) + cstr("SCRAM-SHA-256") + b"\x00"));
    if mode == 3 {
        next(p);
        send(p, hello());
        next(p);
        net.close(p.fd);
        chan_send(verdict, "n/a");
        return;
    }
    // SASLInitialResponse: mechanism, int32 length, client-first
    let first = next(p);
    let mech_end = 0;
    while first.body[mech_end] != 0 {
        mech_end = mech_end + 1;
    }
    let client_first = to_str(first.body[mech_end + 5..]);
    let bare = strings.slice(client_first, 3, len(client_first));   // drop "n,,"
    let cnonce = strings.slice(bare, strings.find(bare, "r=") + 2, len(bare));
    let salt = b"0123456789abcdef";
    let server_first = "r=" + cnonce + "srvnonce,s=" +
                       encoding.base64_encode(salt) + ",i=4096";
    send(p, msg(82, be32(11) + to_bytes(server_first)));

    let fin = next(p);
    let client_final = to_str(fin.body);
    let pidx = strings.find(client_final, ",p=");
    let without_proof = strings.slice(client_final, 0, pidx);
    let pbr = encoding.base64_decode(strings.slice(client_final, pidx + 3,
                                                  len(client_final)));
    let proof = pbr ?? b"";
    // The server's side, from the RFC: verify the client's proof
    // against the stored key.
    let salted = crypto.pbkdf2_sha256(b"hunter2", salt, 4096, 32) ?? b"";
    let client_key = crypto.hmac_sha256(salted, b"Client Key");
    let stored_key = crypto.sha256(client_key);
    let auth = bare + "," + server_first + "," + without_proof;
    let client_sig = crypto.hmac_sha256(stored_key, to_bytes(auth));
    let recovered = proof[..];
    let i = 0;
    while i < len(recovered) && i < len(client_sig) {
        recovered[i] = recovered[i] ^ client_sig[i];
        i = i + 1;
    }
    if len(proof) == 32 && crypto.sha256(recovered) == stored_key {
        chan_send(verdict, "proof ok");
    } else {
        chan_send(verdict, "proof BAD");
    }
    let server_sig = crypto.hmac_sha256(crypto.hmac_sha256(salted, b"Server Key"),
                                        to_bytes(auth));
    if mode == 1 {
        server_sig = crypto.sha256(server_sig);
    }
    if mode != 2 {
        send(p, msg(82, be32(12) + to_bytes("v=" + encoding.base64_encode(server_sig))));
    }
    send(p, hello());
    next(p);
    net.close(p.fd);
}

fn scram_try(mode: int) -> str {
    let lfd = listener();
    let verdict: chan[str] = make_chan(1);
    spawn srv_scram(lfd, mode, verdict);
    let cr = pg.connect(url_for(lfd, "u:hunter2"), soon());
    let v = chan_recv(verdict) ?? "";
    guard let c = cr else let e = err_of(cr) {
        return v + " / " + e;
    }
    pg.close(c);
    return v + " / connected";
}

fn scenario_scram() {
    let honest = scram_try(0);
    if honest != "proof ok / connected" {
        die("scram honest: " + honest);
    }
    let liar = scram_try(1);
    if !strings.contains(liar, "server's signature is wrong") {
        die("scram wrong signature: " + liar);
    }
    let skip = scram_try(2);
    if !strings.contains(skip, "without proving it knows the password") {
        die("scram skipped final: " + skip);
    }
    let early = scram_try(3);
    if !strings.contains(early, "without proving it knows the password") {
        die("scram early ok: " + early);
    }
    let plus = scram_try(4);
    if !strings.contains(plus, "no SASL mechanism") {
        die("scram plus only: " + plus);
    }
    println("ok scram");
}

// ---- scenario: server errors leave the connection usable --------------

fn srv_errors(lfd: i32) {
    let p = accept_peer(lfd);
    startup(p);
    send(p, hello());
    drain_query(p);
    send(p, msg(49, b"") + error_msg("42P01", "relation \"nope\" does not exist") +
            ready(73));
    drain_query(p);
    send(p, msg(67, cstr("UPDATE 3")) + ready(73));
    drain_query(p);     // exec: simple protocol
    send(p, msg(67, cstr("CREATE TABLE")) + msg(67, cstr("INSERT 0 5")) + ready(84));
    drain_query(p);
    // COPY FROM STDIN: the driver must refuse it and resynchronise
    send(p, msg(71, to_be(0)[7..] + be16(0)));
    let refused = next(p);
    let sync = next(p);
    if refused.typ != 102 || sync.typ != 83 {
        send(p, error_msg("XX000", "expected CopyFail then Sync"));
    } else {
        send(p, error_msg("57014", "COPY from stdin failed: " +
                                   to_str(refused.body[..len(refused.body) - 1])));
    }
    send(p, ready(73));
    drain_query(p);
    send(p, msg(67, cstr("SELECT 0")) + ready(73));
    next(p);
    net.close(p.fd);
}

fn scenario_errors() {
    let lfd = listener();
    spawn srv_errors(lfd);
    let c = must_connect(url_for(lfd, "u"));
    let r1 = pg.query(c, "SELECT * FROM nope", pg.no_args(), soon());
    guard let x = r1 else let e = err_of(r1) {
        if e != "ERROR: relation \"nope\" does not exist (SQLSTATE 42P01)" {
            die("server error text: " + e);
        }
        if !pg.usable(c) || pg.sqlstate(e) != "42P01" {
            die("server error broke the connection");
        }
        let r2 = pg.query(c, "UPDATE t SET x = 1", pg.no_args(), soon());
        guard let rows = r2 else let e2 = err_of(r2) {
            die("query after server error: " + e2);
            return;
        }
        if rows.affected != 3 || rows.count != 0 {
            die("update affected");
        }
        let n = pg.exec(c, "CREATE TABLE t (); INSERT ...", soon()) ?? -1;
        if n != 5 || !pg.in_transaction(c) {
            die("exec: last statement's count, and transaction status");
        }
        let cp = pg.query(c, "COPY t FROM STDIN", pg.no_args(), soon());
        guard let y = cp else let e3 = err_of(cp) {
            if !strings.contains(e3, "COPY FROM STDIN is not supported") ||
               pg.sqlstate(e3) != "57014" {
                die("copy: " + e3);
            }
            let r4 = pg.query(c, "SELECT 1", pg.no_args(), soon());
            guard let z = r4 else let e4 = err_of(r4) {
                die("query after copy: " + e4);
                return;
            }
            pg.close(c);
            println("ok errors");
            return;
        }
        die("copy succeeded");
        return;
    }
    die("query on a missing table succeeded");
}

// ---- scenario: broken servers break the connection --------------------
//
// mode 0: a DataRow with the wrong field count. 1: a message claiming
// to be 2 GiB. 2: the server hangs up mid-result. 3: a message type the
// protocol does not have. 4: a DataRow with bytes after its last field.
// 5: a field whose length runs past the end of its DataRow -- into the
// NEXT message, which is still in the buffer.

fn srv_broken(lfd: i32, mode: int) {
    let p = accept_peer(lfd);
    startup(p);
    send(p, hello());
    drain_query(p);
    let head = msg(49, b"") + msg(50, b"") + row_desc(["a", "b"], [23, 23]);
    if mode == 0 {
        send(p, head + msg(68, be16(1) + be32(1) + b"1"));
    } else if mode == 1 {
        send(p, head + b"D\x7f\xff\xff\xff");
    } else if mode == 2 {
        send(p, head + msg(68, be16(2) + be32(1) + b"1" + be32(1) + b"2"));
    } else if mode == 3 {
        send(p, head + msg(63, b""));
    } else if mode == 4 {
        send(p, head + msg(68, be16(2) + be32(1) + b"1" + be32(1) + b"2" + b"xx"));
    } else {
        send(p, head + msg(68, be16(2) + be32(1) + b"1" + be32(20) + b"2") +
                msg(67, cstr("SELECT 1")) + ready(73));
    }
    net.close(p.fd);
}

fn broken_try(mode: int) -> str {
    let lfd = listener();
    spawn srv_broken(lfd, mode);
    let c = must_connect(url_for(lfd, "u"));
    let r = pg.query(c, "SELECT a, b FROM t", pg.no_args(), soon());
    guard let x = r else let e = err_of(r) {
        if pg.usable(c) {
            die("connection still usable after: " + e);
        }
        let again = pg.query(c, "SELECT 1", pg.no_args(), soon());
        guard let y = again else let e2 = err_of(again) {
            if !strings.has_prefix(e2, "connection is broken: ") {
                die("reuse of a broken connection: " + e2);
            }
            pg.close(c);
            return e;
        }
        die("broken connection answered");
        return "";
    }
    die("query on broken server succeeded, mode " + to_str(mode));
    return "";
}

fn scenario_broken() {
    let e0 = broken_try(0);
    if !strings.contains(e0, "row has 1 fields, expected 2") {
        die("field count: " + e0);
    }
    let e1 = broken_try(1);
    if !strings.contains(e1, "protocol error: message length") {
        die("huge message: " + e1);
    }
    let e2 = broken_try(2);
    if e2 != "server closed the connection" {
        die("hangup: " + e2);
    }
    let e3 = broken_try(3);
    if !strings.contains(e3, "unexpected message 63") {
        die("unknown message: " + e3);
    }
    let e4 = broken_try(4);
    if e4 != "protocol error: malformed DataRow" {
        die("trailing bytes: " + e4);
    }
    let e5 = broken_try(5);
    if e5 != "protocol error: malformed DataRow" {
        die("field overrun: " + e5);
    }
    println("ok broken");
}

// ---- scenario: a deadline cancels the query ---------------------------

fn srv_slow(lfd: i32, cancel: chan[str]) {
    let p = accept_peer(lfd);
    startup(p);
    send(p, hello());
    drain_query(p);
    // Never answer. The driver must give up, and ask for a cancel on a
    // NEW connection carrying our pid and secret.
    let q = accept_peer(lfd);
    let req = startup(q);
    if len(req) == 16 && rd32(req, 4) == 80877102 && rd32(req, 8) == 4242 &&
       rd32(req, 12) == 777 {
        chan_send(cancel, "cancel ok");
    } else {
        chan_send(cancel, "bad cancel: " + encoding.hex_encode(req));
    }
    net.close(q.fd);
    net.close(p.fd);
}

fn scenario_timeout() {
    let lfd = listener();
    let cancel: chan[str] = make_chan(1);
    spawn srv_slow(lfd, cancel);
    let c = must_connect(url_for(lfd, "u"));
    let t0 = time.mono();
    let r = pg.query(c, "SELECT pg_sleep(60)", pg.no_args(),
                     until_of(time.mono() + 200000000));
    let took = time.mono() - t0;
    guard let x = r else let e = err_of(r) {
        if e != "timeout" {
            die("timeout text: " + e);
        }
        if took > 2000000000 {
            die("timeout took too long");
        }
        if pg.usable(c) {
            die("timed-out connection still usable");
        }
        let v = chan_recv(cancel) ?? "";
        if v != "cancel ok" {
            die(v);
        }
        // An already-expired deadline fails without touching the
        // connection -- tested on a fresh one below via the pool.
        println("ok timeout");
        return;
    }
    die("slow query succeeded");
}

// ---- scenario: TLS refused by the server ------------------------------

fn srv_no_tls(lfd: i32) {
    let p = accept_peer(lfd);
    let req = startup(p);
    if len(req) == 8 && rd32(req, 4) == 80877103 {
        send(p, b"N");
    }
    net.close(p.fd);
}

fn scenario_tls_refused() {
    let lfd = listener();
    spawn srv_no_tls(lfd);
    let e = connect_error(url_for(lfd, "u") + "?sslmode=require");
    if !strings.contains(e, "does not support TLS; add sslmode=disable") {
        die("tls refused: " + e);
    }
    println("ok tls refused");
}

// ---- scenario: getters panic on NULL and on the wrong type ------------

fn srv_one_row(lfd: i32) {
    let p = accept_peer(lfd);
    startup(p);
    send(p, hello());
    drain_query(p);
    send(p, row_desc(["n", "t"], [23, 25]) +
            msg(68, be16(2) + be32(-1) + be32(2) + b"hi") +
            msg(67, cstr("SELECT 1")) + ready(73));
    next(p);
    net.close(p.fd);
}

fn read_null_int(rows: pg.Rows) -> int {
    return pg.get_int(rows, 0, 0);
}

fn read_text_as_int(rows: pg.Rows) -> int {
    return pg.get_int(rows, 0, 1);
}

fn read_missing_col(rows: pg.Rows) -> int {
    return pg.col(rows, "nope");
}

fn read_bad_row(rows: pg.Rows) -> int {
    return len(pg.get_text(rows, 1, 1));
}

fn panic_text(h: join[int]) -> str {
    let r = join_wait(h);
    guard let v = r else let e = err_of(r) {
        return e;
    }
    return "no panic";
}

fn scenario_getters() {
    let lfd = listener();
    spawn srv_one_row(lfd);
    let c = must_connect(url_for(lfd, "u"));
    let qr = pg.query(c, "SELECT n, t", pg.no_args(), soon());
    guard let rows = qr else let e = err_of(qr) {
        die("query: " + e);
        return;
    }
    pg.close(c);
    let e1 = panic_text(spawn read_null_int(rows));
    if !strings.contains(e1, "column 'n' is NULL in row 0; check pg.is_null") {
        die("null panic: " + e1);
    }
    let e2 = panic_text(spawn read_text_as_int(rows));
    if !strings.contains(e2, "column 't' is text, which pg.get_int does not read") {
        die("type panic: " + e2);
    }
    let e3 = panic_text(spawn read_missing_col(rows));
    if !strings.contains(e3, "no column named 'nope' (columns: n, t)") {
        die("col panic: " + e3);
    }
    let e4 = panic_text(spawn read_bad_row(rows));
    if !strings.contains(e4, "row 1 out of range (1 rows)") {
        die("row panic: " + e4);
    }
    println("ok getters");
}

// ---- scenario: the pool -----------------------------------------------

// Serves `n` connections, each answering queries until the client
// leaves. The ReadyForQuery status of each answer is taken from the
// query text: a query mentioning BEGIN leaves a transaction open.
fn srv_pool_conn(fd: i32) {
    let p = Peer { fd: fd, buf: b"" };
    startup(p);
    send(p, hello());
    while true {
        let g = next(p);
        if g.typ == -1 || g.typ == 88 {
            break;
        }
        if g.typ == 81 {
            let status = 73;
            if strings.contains(to_str(g.body), "BEGIN") {
                status = 84;
            }
            send(p, msg(67, cstr("SELECT 0")) + ready(status));
        }
    }
    net.close(fd);
}

fn srv_pool(lfd: i32) {
    while true {
        let ar = net.accept(lfd);
        guard let fd = ar else {
            return;
        }
        spawn srv_pool_conn(fd);
    }
}

fn release_twice(p: pg.Pool) -> int {
    let ar = pg.acquire(p, soon());
    guard let c = ar else {
        return 0;
    }
    pg.release(p, c);
    pg.release(p, c);
    return 1;
}

fn scenario_pool() {
    let lfd = listener();
    spawn srv_pool(lfd);
    let pr = pg.new_pool(url_for(lfd, "u"), 1);
    guard let p = pr else let e = err_of(pr) {
        die("new_pool: " + e);
        return;
    }
    let n = pg.pool_exec(p, "SELECT 1", soon()) ?? -1;
    let n2 = pg.pool_exec(p, "SELECT 1", soon()) ?? -1;
    if n != 0 || n2 != 0 || p.dials != 1 || p.reuses != 1 || p.open != 1 {
        die("pool reuse: dials " + to_str(p.dials) + " reuses " + to_str(p.reuses));
    }

    // max_open 1 and it is taken: a second acquire waits, then times out
    let ar = pg.acquire(p, soon());
    guard let c = ar else let e = err_of(ar) {
        die("acquire: " + e);
        return;
    }
    let t0 = time.mono();
    let wr = pg.acquire(p, until_of(time.mono() + 100000000));
    guard let c2 = wr else let e = err_of(wr) {
        if e != "timeout" || time.mono() - t0 < 100000000 {
            die("exhausted pool: " + e);
        }
        // Released inside a transaction: closed, never handed on.
        pg.exec(c, "BEGIN", soon());
        if !pg.in_transaction(c) {
            die("in_transaction");
        }
        pg.release(p, c);
        if p.open != 0 || len(p.idle) != 0 || pg.usable(c) {
            die("a connection released mid-transaction was kept");
        }
        pg.pool_exec(p, "SELECT 1", soon());
        if p.dials != 2 {
            die("expected a fresh dial after the transaction was discarded");
        }
        let e2 = panic_text(spawn release_twice(p));
        if !strings.contains(e2, "released twice") {
            die("double release: " + e2);
        }
        // An already-expired deadline fails before touching anything.
        let late = pg.pool_exec(p, "SELECT 1", until_of(time.mono() - 1));
        guard let l = late else let e3 = err_of(late) {
            if e3 != "timeout" || p.open != 1 || len(p.idle) != 1 {
                die("expired deadline: " + e3 + " open " + to_str(p.open));
            }
            pg.pool_close(p);
            if p.open != 0 {
                die("pool_close left connections open");
            }
            let closed = pg.pool_exec(p, "SELECT 1", soon());
            guard let z = closed else let e4 = err_of(closed) {
                if e4 != "pool is closed" {
                    die("closed pool: " + e4);
                }
                println("ok pool");
                return;
            }
            die("closed pool served a query");
            return;
        }
        die("expired deadline served a query");
        return;
    }
    die("second acquire on a full pool succeeded");
}

// A scenario whose failure is a missing message would otherwise wait
// forever rather than fail.
fn watchdog() {
    time.sleep(60000000000);
    die("test hung");
}

spawn watchdog();
scenario_query();
scenario_passwords();
scenario_scram();
scenario_errors();
scenario_broken();
scenario_timeout();
scenario_tls_refused();
scenario_getters();
scenario_pool();
