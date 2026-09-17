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
// session really is encrypted.

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

    let rows = q(c, "SELECT * FROM slang_vals ORDER BY i8 DESC", pg.no_args());
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
    let syn = query_error(c, "SELEC 1", pg.no_args());
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
    let aborted = query_error(c, "SELECT 1", pg.no_args());
    if pg.sqlstate(aborted) != "25P02" || !pg.in_transaction(c) {
        die("failed transaction: " + aborted);
    }
    ex(c, "ROLLBACK");
    if pg.in_transaction(c) || pg.get_int(q(c, "SELECT count(*) FROM slang_tx", pg.no_args()), 0, 0) != 1 {
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
    let r = pg.query(c, "SELECT pg_sleep(30) /* slang-cancel-probe */", pg.no_args(),
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
                pg.no_args()), 0, 0);
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

// ---- large results ----------------------------------------------------

fn large() {
    let c = conn();
    let t0 = time.mono();
    let rows = q(c, "SELECT g, md5(g::text) FROM generate_series(1, 200000) g", pg.no_args());
    let sum = 0;
    let r = 0;
    while r < rows.count {
        sum = sum + pg.get_int(rows, r, 0);
        r = r + 1;
    }
    if rows.count != 200000 || sum != 20000100000 || len(pg.get_text(rows, 199999, 1)) != 32 {
        die("200k rows");
    }
    let big = q(c, "SELECT repeat('x', 20000000)", pg.no_args());
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
    let rows = q(c, "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()", pg.no_args());
    if !pg.get_bool(rows, 0, 0) {
        die("session is not encrypted");
    }
    pg.close(c);
    println("ok tls");
}

values();
errors();
cancel();
pool();
large();
tls();
