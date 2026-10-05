import "pg";
import "proc";
import "time";
import "strings";

// The pg driver against a REAL Postgres. Not part of `make test`, which
// must run without one; CI runs it against a service container, and
// locally:
//
//   docker run -d --name slang-pg -e POSTGRES_USER=slang \
//       -e POSTGRES_PASSWORD=secret -p 55432:5432 postgres:16
//   PG_URL=postgres://slang:secret@127.0.0.1:55432/slang \
//       ./slangc tests/live/postgres/main.sl --run
//
// PG_TLS_URL, if set, is a server with TLS on: the test checks the
// session really is encrypted. PG_SOCKET_URL, if set, reaches the server
// over a Unix-domain socket.

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn soon() -> until {
    return until_of(time.mono() + 30000000000);
}

fn url() -> str {
    guard let u = proc.getenv("PG_URL") else {
        die("PG_URL is not set");
        return "";
    }
    return u;
}

fn conn() -> pg.Conn {
    let cr = pg.connect(url(), soon());
    guard let c = cr else let e = err_of(cr) {
        die("connect: " + e);
        panic("unreachable");
    }
    return c;
}

fn q(c: pg.Conn, sql: str, args: [pg.Arg]) -> pg.Rows {
    let r = pg.query(c, sql, args, soon());
    guard let rows = r else let e = err_of(r) {
        die(sql + ": " + e);
        panic("unreachable");
    }
    return rows;
}

fn ex(c: pg.Conn, sql: str) -> int {
    let r = pg.exec(c, sql, soon());
    guard let n = r else let e = err_of(r) {
        die(sql + ": " + e);
        return 0;
    }
    return n;
}

fn query_error(c: pg.Conn, sql: str, args: [pg.Arg]) -> str {
    let r = pg.query(c, sql, args, soon());
    guard let rows = r else let e = err_of(r) {
        return e;
    }
    die("should have failed: " + sql);
    return "";
}

// ---- values round-trip ------------------------------------------------

fn values() {
    let c = conn();
    ex(c, "DROP TABLE IF EXISTS slang_vals; CREATE TABLE slang_vals " +
          "(i8 int8, i4 int4, i2 int2, f8 float8, f4 float4, num numeric, " +
          "t text, b bool, raw bytea, ts timestamptz, j jsonb, u uuid)");

    let all = b"";
    let k = 0;
    while k < 256 {
        all = all + to_be(k)[7..];
        k = k + 1;
    }
    let ins = q(c, "INSERT INTO slang_vals VALUES " +
                   "($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12), " +
                   "($13, NULL, NULL, $14, NULL, NULL, $15, $16, $17, NULL, NULL, NULL)",
        [pg.arg_int(9223372036854775807), pg.arg_int(-2147483648),
         pg.arg_int(-32768), pg.arg_float(0.1 + 0.2), pg.arg_float(1.5),
         pg.arg_text("12345678901234567890.123456789"),
         pg.arg_text("zoë — 日本語 'quoted' \\ backslash"),
         pg.arg_bool(true), pg.arg_bytes(all),
         pg.arg_text("2024-02-29 12:34:56.789+00"),
         pg.arg_text("{\"a\": [1, 2]}"),
         pg.arg_text("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"),
         pg.arg_int(-9223372036854775807 - 1), pg.arg_float(-0.0),
         pg.arg_text(""), pg.arg_bool(false), pg.arg_bytes(b"")]);
    if ins.affected != 2 || ins.tag != "INSERT 0 2" {
        die("insert tag: " + ins.tag);
    }

    let rows = q(c, "SELECT * FROM slang_vals ORDER BY i8 DESC", []);
    if rows.count != 2 || len(rows.columns) != 12 {
        die("shape");
    }
    if pg.get_int(rows, 0, pg.col(rows, "i8")) != 9223372036854775807 ||
       pg.get_int(rows, 0, 1) != -2147483648 || pg.get_int(rows, 0, 2) != -32768 {
        die("ints");
    }
    if pg.get_float(rows, 0, 3) != 0.1 + 0.2 || pg.get_float(rows, 0, 4) != 1.5 {
        die("floats: " + pg.get_text(rows, 0, 3));
    }
    // numeric keeps every digit as text; as a float it rounds
    if pg.get_text(rows, 0, 5) != "12345678901234567890.123456789" ||
       pg.get_float(rows, 0, 5) != 12345678901234567890.123456789 {
        die("numeric");
    }
    if pg.get_text(rows, 0, 6) != "zoë — 日本語 'quoted' \\ backslash" {
        die("text: " + pg.get_text(rows, 0, 6));
    }
    if !pg.get_bool(rows, 0, 7) || pg.get_bytes(rows, 0, 8) != all {
        die("bool / all 256 byte values");
    }
    if pg.get_text(rows, 0, 9) != "2024-02-29 12:34:56.789+00" ||
       pg.get_text(rows, 0, 10) != "{\"a\": [1, 2]}" ||
       pg.get_text(rows, 0, 11) != "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11" {
        die("timestamptz/jsonb/uuid: " + pg.get_text(rows, 0, 9));
    }
    if pg.get_int(rows, 1, 0) != -9223372036854775807 - 1 ||
       !pg.is_null(rows, 1, 1) || pg.get_text(rows, 1, 6) != "" ||
       pg.get_bool(rows, 1, 7) || len(pg.get_bytes(rows, 1, 8)) != 0 ||
       !pg.is_null(rows, 1, 11) {
        die("row 2");
    }
    // A parameter can never become SQL, whatever it contains.
    let inj = q(c, "SELECT count(*) FROM slang_vals WHERE t = $1",
                [pg.arg_text("x' OR '1'='1")]);
    if pg.get_int(inj, 0, 0) != 0 {
        die("a parameter was parsed as SQL");
    }
    ex(c, "DROP TABLE slang_vals");
    pg.close(c);
    println("ok values");
}

// ---- errors and transactions ------------------------------------------

fn errors() {
    let c = conn();
    let syn = query_error(c, "SELEC 1", []);
    if pg.sqlstate(syn) != "42601" || !strings.contains(syn, "syntax error") {
        die("syntax: " + syn);
    }
    ex(c, "DROP TABLE IF EXISTS slang_tx; CREATE TABLE slang_tx (id int PRIMARY KEY)");
    q(c, "INSERT INTO slang_tx VALUES ($1)", [pg.arg_int(1)]);
    let dup = query_error(c, "INSERT INTO slang_tx VALUES ($1)", [pg.arg_int(1)]);
    if pg.sqlstate(dup) != "23505" {
        die("unique: " + dup);
    }
    let arity = query_error(c, "SELECT $1::int + $2::int", [pg.arg_int(1)]);
    if pg.sqlstate(arity) != "08P01" {
        die("parameter count: " + arity);
    }

    ex(c, "BEGIN");
    q(c, "INSERT INTO slang_tx VALUES ($1)", [pg.arg_int(2)]);
    if !pg.in_transaction(c) {
        die("BEGIN not seen");
    }
    query_error(c, "INSERT INTO slang_tx VALUES ($1)", [pg.arg_int(1)]);
    let aborted = query_error(c, "SELECT 1", []);
    if pg.sqlstate(aborted) != "25P02" || !pg.in_transaction(c) {
        die("failed transaction: " + aborted);
    }
    ex(c, "ROLLBACK");
    if pg.in_transaction(c) || pg.get_int(q(c, "SELECT count(*) FROM slang_tx", []), 0, 0) != 1 {
        die("rollback");
    }
    // several statements, one call; the count is the last one's
    let n = ex(c, "INSERT INTO slang_tx VALUES (10), (11); UPDATE slang_tx SET id = id + 100 WHERE id >= 10");
    if n != 2 {
        die("exec count " + to_str(n));
    }
    ex(c, "DROP TABLE slang_tx");
    pg.close(c);

    let bad = strings.replace(url(), ":secret@", ":wrong@");
    let br = pg.connect(bad, soon());
    guard let b = br else let e = err_of(br) {
        if pg.sqlstate(e) != "28P01" {
            die("wrong password: " + e);
        }
        println("ok errors");
        return;
    }
    die("wrong password accepted");
}

// ---- a timeout cancels the query on the server ------------------------

fn cancel() {
    let c = conn();
    let t0 = time.mono();
    let r = pg.query(c, "SELECT pg_sleep(30) /* slang-cancel-probe */", [],
                     until_of(time.mono() + 300000000));
    guard let x = r else let e = err_of(r) {
        if e != "timeout" || time.mono() - t0 > 2000000000 {
            die("timeout: " + e);
        }
        // The cancel goes out on its own task; give the server a moment.
        let watcher = conn();
        let tries = 0;
        while tries < 50 {
            let n = pg.get_int(q(watcher,
                "SELECT count(*) FROM pg_stat_activity WHERE state = 'active' " +
                "AND query LIKE '%slang-cancel-probe%' AND pid <> pg_backend_pid()",
                []), 0, 0);
            if n == 0 {
                pg.close(watcher);
                println("ok cancel");
                return;
            }
            time.sleep(100000000);
            tries = tries + 1;
        }
        die("the server is still running the timed-out query");
        return;
    }
    die("pg_sleep(30) returned inside 300ms");
}

// ---- the pool, under concurrent tasks ---------------------------------

fn worker(p: pg.Pool, id: int) -> int {
    let r = pg.pool_query(p, "SELECT $1::int8 * 2, pg_sleep(0.2)", [pg.arg_int(id)],
                          soon());
    guard let rows = r else let e = err_of(r) {
        panic("worker " + to_str(id) + ": " + e);
    }
    return pg.get_int(rows, 0, 0);
}

fn pool() {
    let pr = pg.new_pool(url(), 8);
    guard let p = pr else let e = err_of(pr) {
        die("new_pool: " + e);
        return;
    }
    let t0 = time.mono();
    let hs: [join[int]] = [];
    let i = 0;
    while i < 32 {
        push(hs, spawn worker(p, i));
        i = i + 1;
    }
    let sum = 0;
    for h in hs {
        let r = join_wait(h);
        guard let v = r else let e = err_of(r) {
            die(e);
            return;
        }
        sum = sum + v;
    }
    let took = time.mono() - t0;
    // 32 queries of 200ms each: 6.4s one at a time, ~0.8s eight at a
    // time. Well under 3s shows they ran concurrently, on tasks that
    // parked rather than blocked their workers.
    if sum != 992 || took > 3000000000 || p.dials > 8 || p.open > 8 {
        die("pool: sum " + to_str(sum) + " took " + to_str(took / 1000000) +
            "ms dials " + to_str(p.dials));
    }
    pg.pool_close(p);
    println("ok pool");
}

// ---- the pool's waiters: order, deadlines, close ----------------------

fn pool_of(n: int) -> pg.Pool {
    let pr = pg.new_pool(url(), n);
    guard let p = pr else let e = err_of(pr) {
        die("new_pool: " + e);
        panic("unreachable");
    }
    return p;
}

fn take(p: pg.Pool) -> pg.Conn {
    let ar = pg.acquire(p, soon());
    guard let c = ar else let e = err_of(ar) {
        die("acquire: " + e);
        panic("unreachable");
    }
    return c;
}

fn in_line(p: pg.Pool, id: int, order: chan[int]) -> int {
    let c = take(p);
    chan_send(order, id);
    time.sleep(5000000);
    pg.release(p, c);
    return id;
}

fn short_wait(p: pg.Pool) -> str {
    let ar = pg.acquire(p, until_of(time.mono() + 100000000));
    guard let c = ar else let e = err_of(ar) {
        return e;
    }
    pg.release(p, c);
    return "got a connection";
}

// Waiters are served in arrival order, a release wakes the next one at
// once, a deadline ends a wait, and closing the pool ends every wait.
// The pool used to poll every 2ms: whichever waiter polled first after
// a release won, so with eight waiters the order was a lottery.
fn pool_waiters() {
    let p = pool_of(1);
    let held = take(p);
    let order: chan[int] = make_chan(16);
    let hs: [join[int]] = [];
    let i = 0;
    while i < 8 {
        push(hs, spawn in_line(p, i, order));
        time.sleep(20000000);   // each is parked before the next arrives
        i = i + 1;
    }
    pg.release(p, held);
    let got = "";
    i = 0;
    while i < 8 {
        got = got + to_str(chan_recv(order) ?? -1) + " ";
        i = i + 1;
    }
    for h in hs {
        let r = join_wait(h);
        guard let _v = r else let e = err_of(r) {
            die(e);
            return;
        }
    }
    if got != "0 1 2 3 4 5 6 7 " {
        die("pool waiters: served in order " + got);
    }

    // a deadline ends the wait, and the pool is still whole after it
    held = take(p);
    let t0 = time.mono();
    let e = short_wait(p);
    let took = time.mono() - t0;
    if e != "timeout" || took < 100000000 || took > 1000000000 {
        die("pool waiters: deadline gave '" + e + "' after " +
            to_str(took / 1000000) + "ms");
    }
    pg.release(p, held);
    held = take(p);
    if p.open != 1 || p.dials != 1 {
        die("pool waiters: open " + to_str(p.open) + " dials " +
            to_str(p.dials) + " after a timeout");
    }

    // closing the pool fails a waiting acquire
    let w = spawn short_wait(p);
    time.sleep(20000000);
    pg.pool_close(p);
    let wr = join_wait(w);
    guard let we = wr else let je = err_of(wr) {
        die(je);
        return;
    }
    if we != "pool is closed" {
        die("pool waiters: after close, '" + we + "'");
    }
    pg.release(p, held);
    println("ok pool waiters");
}

// ---- prepared statements ----------------------------------------------

fn conn_url(u: str) -> pg.Conn {
    let cr = pg.connect(u, soon());
    guard let c = cr else let e = err_of(cr) {
        die("connect: " + e);
        panic("unreachable");
    }
    return c;
}

// How many named statements the server holds for this session, and how
// many of them are `sql`. The counting query is itself one of them.
fn prepared(c: pg.Conn, sql: str) -> str {
    let rows = q(c, "SELECT count(*), count(*) FILTER (WHERE statement = $1) " +
                    "FROM pg_prepared_statements", [pg.arg_text(sql)]);
    return to_str(pg.get_int(rows, 0, 0)) + "/" + to_str(pg.get_int(rows, 0, 1));
}

// query() prepares each SQL text once per connection and reuses it; the
// cache is bounded, survives the server dropping or invalidating a
// statement, and a failed first use leaves nothing behind. Before the
// cache, every query was parsed and planned again: no named statement
// ever existed.
fn statements() {
    let c = conn();
    let sql = "SELECT $1::int8 + 1";
    let i = 0;
    while i < 5 {
        if pg.get_int(q(c, sql, [pg.arg_int(i)]), 0, 0) != i + 1 {
            die("statements: wrong result");
        }
        i = i + 1;
    }
    let got = prepared(c, sql);
    if got != "2/1" {
        die("statements: prepared " + got + ", want 2/1 (the query and " +
            "the counting query, once each)");
    }

    // a schema change that alters the result type: re-prepared, retried
    ex(c, "DROP TABLE IF EXISTS stmt_shape");
    ex(c, "CREATE TABLE stmt_shape (a int)");
    ex(c, "INSERT INTO stmt_shape VALUES (1)");
    let shape = "SELECT * FROM stmt_shape";
    q(c, shape, []);
    ex(c, "ALTER TABLE stmt_shape ADD COLUMN b int");
    let wide = q(c, shape, []);
    if len(wide.columns) != 2 {
        die("statements: after ALTER, " + to_str(len(wide.columns)) +
            " columns");
    }

    // DEALLOCATE ALL drops every statement: the driver forgets them too,
    // so a transaction's first query does not fail on a missing one
    ex(c, "DEALLOCATE ALL");
    ex(c, "BEGIN");
    if pg.get_int(q(c, sql, [pg.arg_int(41)]), 0, 0) != 42 {
        die("statements: after DEALLOCATE ALL");
    }
    ex(c, "COMMIT");

    // dropped behind the driver's back (another statement's DEALLOCATE):
    // outside a transaction, re-prepared and retried
    let held = q(c, "SELECT name FROM pg_prepared_statements WHERE statement = $1",
                 [pg.arg_text(sql)]);
    ex(c, "DEALLOCATE " + pg.get_text(held, 0, 0));
    if pg.get_int(q(c, sql, [pg.arg_int(1)]), 0, 0) != 2 {
        die("statements: after DEALLOCATE of one");
    }

    // inside a transaction the stale statement's error is returned, not
    // retried (the transaction is already aborted); after ROLLBACK the
    // statement is prepared afresh
    ex(c, "BEGIN");
    q(c, shape, []);
    ex(c, "ALTER TABLE stmt_shape ADD COLUMN c int");
    ex(c, "SAVEPOINT s");
    let e = query_error(c, shape, []);
    if pg.sqlstate(e) != "0A000" {
        die("statements: in a transaction, '" + e + "'");
    }
    ex(c, "ROLLBACK");
    if len(q(c, shape, []).columns) != 2 {
        die("statements: after ROLLBACK");
    }

    // a failed first use is not kept
    let bad = "SELEC 1";
    query_error(c, bad, []);
    got = prepared(c, bad);
    if !strings.has_suffix(got, "/0") {
        die("statements: a failed parse left " + got);
    }
    ex(c, "DROP TABLE stmt_shape");
    pg.close(c);

    // bounded: capacity 2 never holds more than 2
    let small = conn_url(url() + sep() + "statement_cache_capacity=2");
    i = 0;
    while i < 6 {
        q(small, "SELECT " + to_str(i), []);
        i = i + 1;
    }
    got = prepared(small, "");
    if !strings.has_prefix(got, "2/") {
        die("statements: capacity 2 holds " + got);
    }
    pg.close(small);

    // capacity 0: nothing is prepared
    let off = conn_url(url() + sep() + "statement_cache_capacity=0");
    q(off, sql, [pg.arg_int(1)]);
    got = prepared(off, sql);
    if got != "0/0" {
        die("statements: capacity 0 holds " + got);
    }
    pg.close(off);
    println("ok statements");
}

fn sep() -> str {
    if strings.contains(url(), "?") {
        return "&";
    }
    return "?";
}

// ---- binary results ---------------------------------------------------

// Every getter's view of one row, as text, for comparing two runs.
fn row_view(rows: pg.Rows) -> str {
    let out = "";
    let c = 0;
    while c < len(rows.columns) {
        if pg.is_null(rows, 0, c) {
            out = out + "NULL|";
        } else {
            let t = rows.types[c];
            out = out + pg.get_text(rows, 0, c);
            if t == 20 || t == 21 || t == 23 {
                out = out + "/" + to_str(pg.get_int(rows, 0, c)) + "/" +
                      to_str(pg.get_float(rows, 0, c));
            } else if t == 16 {
                out = out + "/" + to_str(pg.get_bool(rows, 0, c));
            } else if t == 17 {
                out = out + "/" + to_str(len(pg.get_bytes(rows, 0, c)));
            }
            out = out + "|";
        }
        c = c + 1;
    }
    return out;
}

// A cached statement's second run reads int, bool and bytea columns in
// binary; every getter must see exactly what the first, text run saw,
// at the edges of each type.
fn binary_results() {
    let c = conn();
    let sql = "SELECT (-32768)::int2, 32767::int2, (-2147483648)::int4, " +
              "2147483647::int4, (-9223372036854775808)::int8, " +
              "9223372036854775807::int8, 0::int8, true, false, " +
              "'\\x00ff'::bytea, ''::bytea, NULL::int8, NULL::bool, " +
              "1.5::float8, 'x'::text, $1::int8";
    let first = q(c, sql, [pg.arg_int(-7)]);
    let second = q(c, sql, [pg.arg_int(-7)]);
    if first.binary[0] || !second.binary[0] || second.binary[13] ||
       second.binary[14] {
        die("binary results: formats " + to_str(first.binary[0]) + " " +
            to_str(second.binary[0]));
    }
    let a = row_view(first);
    let b = row_view(second);
    if a != b {
        die("binary results differ:\n text   " + a + "\n binary " + b);
    }
    if !strings.contains(b, "-9223372036854775808/-9223372036854775808") ||
       !strings.contains(b, "\\x00ff/2|") {
        die("binary results: " + b);
    }
    // off: never binary
    let off = conn_url(url() + sep() + "statement_cache_capacity=0");
    q(off, sql, [pg.arg_int(1)]);
    if q(off, sql, [pg.arg_int(1)]).binary[0] {
        die("binary results with the cache off");
    }
    pg.close(off);
    pg.close(c);
    println("ok binary results");
}

// ---- large results ----------------------------------------------------

fn large() {
    let c = conn();
    let t0 = time.mono();
    let rows = q(c, "SELECT g, md5(g::text) FROM generate_series(1, 200000) g", []);
    let sum = 0;
    let r = 0;
    while r < rows.count {
        sum = sum + pg.get_int(rows, r, 0);
        r = r + 1;
    }
    if rows.count != 200000 || sum != 20000100000 || len(pg.get_text(rows, 199999, 1)) != 32 {
        die("200k rows");
    }
    let big = q(c, "SELECT repeat('x', 20000000)", []);
    if len(pg.get_text(big, 0, 0)) != 20000000 {
        die("20 MB value");
    }
    let took = time.mono() - t0;
    if took > 20000000000 {
        die("large results took " + to_str(took / 1000000) + "ms");
    }
    pg.close(c);
    println("ok large");
}

// ---- TLS --------------------------------------------------------------

fn tls() {
    guard let u = proc.getenv("PG_TLS_URL") else {
        println("ok tls (skipped: PG_TLS_URL not set)");
        return;
    }
    let cr = pg.connect(u, soon());
    guard let c = cr else let e = err_of(cr) {
        die("tls connect: " + e);
        return;
    }
    let rows = q(c, "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()", []);
    if !pg.get_bool(rows, 0, 0) {
        die("session is not encrypted");
    }
    pg.close(c);
    println("ok tls");
}

// ---- COPY ---------------------------------------------------------------

fn copy() {
    let c = conn();
    ex(c, "DROP TABLE IF EXISTS slang_copy; CREATE TABLE slang_copy (id int, name text)");
    let parts: [str] = [];
    let i = 0;
    while i < 100000 {
        push(parts, to_str(i) + ",name " + to_str(i) + "\n");
        i = i + 1;
    }
    let csv = to_bytes(strings.join(parts, ""));
    let nr = pg.copy_from(c, "COPY slang_copy FROM STDIN (FORMAT csv)", csv, soon());
    guard let n = nr else let e = err_of(nr) {
        die("copy_from: " + e);
        return;
    }
    if n != 100000 {
        die("copy_from count " + to_str(n));
    }
    let bad = pg.copy_from(c, "COPY slang_copy FROM STDIN (FORMAT csv)",
                           b"1,ok\nnot a number,x\n", soon());
    guard let b = bad else let e = err_of(bad) {
        if pg.sqlstate(e) != "22P02" {
            die("bad copy data: " + e);
        }
        let out = pg.copy_to(c, "COPY (SELECT id, name FROM slang_copy ORDER BY id) TO STDOUT (FORMAT csv)",
                             soon());
        guard let dumped = out else let e2 = err_of(out) {
            die("copy_to: " + e2);
            return;
        }
        if dumped != csv {
            die("copy round trip differs");
        }
        ex(c, "DROP TABLE slang_copy");
        pg.close(c);
        println("ok copy");
        return;
    }
    die("bad copy data was loaded");
}

// ---- streaming ----------------------------------------------------------

fn streaming() {
    let c = conn();
    let sr = pg.stream(c, "SELECT g FROM generate_series(1, 1000000) g", [], soon());
    guard let rows = sr else let e = err_of(sr) {
        die("stream: " + e);
        return;
    }
    let sum = 0;
    let n = 0;
    while true {
        let nr = pg.next_row(c, rows, soon());
        guard let more = nr else let e = err_of(nr) {
            die("next_row: " + e);
            return;
        }
        if !more {
            break;
        }
        sum = sum + pg.get_int(rows, 0, 0);
        n = n + 1;
    }
    if n != 1000000 || sum != 500000500000 || rows.affected != 1000000 {
        die("streamed " + to_str(n));
    }
    // closed early: the server must stop generating, and the connection
    // must be usable straight away
    let br = pg.stream(c, "SELECT g, pg_sleep(0.001) FROM generate_series(1, 100000) g",
                       [], soon());
    guard let big = br else let e = err_of(br) {
        die("stream to close: " + e);
        return;
    }
    pg.next_row(c, big, soon());
    let t0 = time.mono();
    let cr = pg.stream_close(c, big, soon());
    guard let closed = cr else let e = err_of(cr) {
        die("stream_close: " + e);
        return;
    }
    if time.mono() - t0 > 5000000000 {
        die("stream_close waited for the query instead of cancelling it");
    }
    if pg.get_int(q(c, "SELECT 7", []), 0, 0) != 7 {
        die("query after stream_close");
    }
    pg.close(c);
    println("ok streaming");
}

// ---- LISTEN / NOTIFY ----------------------------------------------------

fn notifications() {
    let listener = conn();
    let talker = conn();
    let lr = pg.listen(listener, "slang \"events\"", soon());
    guard let l = lr else let e = err_of(lr) {
        die("listen: " + e);
        return;
    }
    let idle = pg.wait_notification(listener, until_of(time.mono() + 200000000));
    guard let nothing = idle else let e = err_of(idle) {
        die("idle wait: " + e);
        return;
    }
    guard let unexpected = nothing else {
        pg.notify(talker, "slang \"events\"", "first", soon());
        ex(talker, "NOTIFY \"slang \"\"events\"\"\", 'second'");
        let a = pg.wait_notification(listener, soon()) ?? none;
        let b = pg.wait_notification(listener, soon()) ?? none;
        guard let na = a else {
            die("first notification missing");
            return;
        }
        guard let nb = b else {
            die("second notification missing");
            return;
        }
        if na.payload != "first" || nb.payload != "second" ||
           na.channel != "slang \"events\"" {
            die("notifications: " + na.channel + " " + na.payload + " " + nb.payload);
        }
        pg.close(listener);
        pg.close(talker);
        println("ok notifications");
        return;
    }
    die("a notification arrived before any was sent");
}

// ---- the connect deadline -----------------------------------------------

fn connect_deadline() {
    // the whole connect, against a real server, inside a short deadline
    let cr = pg.connect(url(), until_of(time.mono() + 5000000000));
    guard let c = cr else let e = err_of(cr) {
        die("connect within 5s: " + e);
        return;
    }
    pg.close(c);
    let late = pg.connect(url(), until_of(time.mono() - 1));
    guard let x = late else let e = err_of(late) {
        if e != "timeout" {
            die("expired connect deadline: " + e);
        }
        println("ok connect deadline");
        return;
    }
    die("connected with an expired deadline");
}

// ---- Unix-domain socket -------------------------------------------------

fn unix_socket() {
    guard let u = proc.getenv("PG_SOCKET_URL") else {
        println("ok unix socket (skipped: PG_SOCKET_URL not set)");
        return;
    }
    let cr = pg.connect(u, soon());
    guard let c = cr else let e = err_of(cr) {
        die("unix socket connect: " + e);
        return;
    }
    // client_addr is NULL exactly when the session came over a socket
    let rows = q(c, "SELECT client_addr IS NULL FROM pg_stat_activity WHERE pid = pg_backend_pid()",
                 []);
    if !pg.get_bool(rows, 0, 0) {
        die("session is not over a unix socket");
    }
    pg.close(c);
    println("ok unix socket");
}

values();
errors();
cancel();
pool();
pool_waiters();
statements();
binary_results();
large();
tls();
copy();
streaming();
notifications();
connect_deadline();
unix_socket();
