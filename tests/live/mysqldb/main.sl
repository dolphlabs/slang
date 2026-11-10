// The mysql client against real servers: MySQL 8.4 and MariaDB 11, each
// named by an env var (unset ones are skipped). See the CI job `mysql`
// for how they are started, and setup-*.sql here for their users.
//
//   MYSQL_URL        mysql://sha2:sha2-pw@localhost:53306/slangtest?sslmode=require&sslrootcert=...
//   MYSQL_NATIVE_URL mysql://native:native-pw@127.0.0.1:53306/slangtest
//   MYSQL_SHA2_URL   mysql://sha2:sha2-pw@127.0.0.1:53306/slangtest     (no TLS)
//   MYSQL_SHA256_URL mysql://sha256:sha256-pw@127.0.0.1:53306/slangtest?allow_public_key_retrieval=true
//   MARIADB_URL      mysql://native:native-pw@127.0.0.1:53307/slangtest

import "decimal";
import "mysql";
import "proc";
import "strings";
import "time";
import "timez";

fn soon() -> until {
    return until_of(time.mono() + 30000000000);
}

fn check(ok_: bool, what: str) {
    if !ok_ {
        panic("FAIL " + what);
    }
}

fn conn(url: str) -> mysql.Conn {
    let r = mysql.connect(url, soon());
    guard let c = r else let e = err_of(r) { panic("connect: " + e); }
    return c;
}

fn run(c: mysql.Conn, sql: str) {
    let r = mysql.exec(c, sql, soon());
    guard let _n = r else let e = err_of(r) { panic(sql + ": " + e); }
}

fn q(c: mysql.Conn, sql: str, args: [mysql.Arg]) -> mysql.Rows {
    let r = mysql.query(c, sql, args, soon());
    guard let rows = r else let e = err_of(r) { panic(sql + ": " + e); }
    return rows;
}

gc struct Thing {
    id: int,
    name: str,
    price: float,
    active: bool,
    note: opt[str],
    data: bytes,
    made: timez.Time,
}

fn types(c: mysql.Conn, maria: bool) {
    run(c, "DROP TABLE IF EXISTS t_types");
    run(c, "CREATE TABLE t_types (id BIGINT PRIMARY KEY AUTO_INCREMENT, ti TINYINT, si SMALLINT, mi MEDIUMINT, " +
           "i INT, ui INT UNSIGNED, bi BIGINT, ubi BIGINT UNSIGNED, f FLOAT, d DOUBLE, dec_ DECIMAL(20,4), " +
           "flag BOOL, s VARCHAR(100), txt TEXT, bin VARBINARY(20), blb BLOB, dt DATE, dtt DATETIME(6), " +
           "tm TIME(3), yr YEAR, bt BIT(12), en ENUM('a','b'), js JSON)");
    let ins = mysql.query(c, "INSERT INTO t_types (ti, si, mi, i, ui, bi, ubi, f, d, dec_, flag, s, txt, bin, blb, dt, dtt, tm, yr, bt, en, js) " +
                          "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, b'101010101010', ?, ?)",
                          [mysql.arg_int(-128), mysql.arg_int(-32768), mysql.arg_int(-8388608), mysql.arg_int(-2147483648),
                           mysql.arg_int(4294967295), mysql.arg_int(-9223372036854775807 - 1),
                           mysql.arg_text("18446744073709551615"), mysql.arg_float(1.5), mysql.arg_float(0.1),
                           mysql.arg_decimal(decimal.parse("1234567890123456.7891") ?? decimal.zero()), mysql.arg_bool(true),
                           mysql.arg_text("héllo ☃"), mysql.arg_text(strings.repeat("x", 3000)), mysql.arg_bytes(b"\x00\x01\xff"),
                           mysql.arg_bytes(b"blob\x00data"), mysql.arg_text("2024-02-29"),
                           mysql.arg_time(timez.parse_rfc3339("2024-02-29T13:14:15.123456Z") ?? timez.unix(0)),
                           mysql.arg_text("-838:59:58.5"), mysql.arg_int(2024), mysql.arg_text("b"),
                           mysql.arg_text("{\"k\": [1, 2]}")], soon());
    guard let ir = ins else let e = err_of(ins) { panic("insert: " + e); }
    check(ir.affected == 1 && ir.last_insert_id == 1, "insert reports 1 row, id 1");
    let rows = q(c, "SELECT * FROM t_types WHERE id = ?", [mysql.arg_int(1)]);
    let want: map[str]str = {};
    want["ti"] = "-128";
    want["si"] = "-32768";
    want["mi"] = "-8388608";
    want["i"] = "-2147483648";
    want["ui"] = "4294967295";
    want["bi"] = "-9223372036854775808";
    want["ubi"] = "18446744073709551615";
    want["f"] = "1.5";
    want["d"] = "0.1";
    want["dec_"] = "1234567890123456.7891";
    want["flag"] = "1";
    want["s"] = "héllo ☃";
    want["dt"] = "2024-02-29";
    want["dtt"] = "2024-02-29 13:14:15.123456";
    want["tm"] = "-838:59:58.500";
    want["yr"] = "2024";
    want["en"] = "b";
    for name, v in want {
        let got = mysql.get_text(rows, 0, mysql.col(rows, name));
        check(got == v, name + ": " + got + " != " + v);
    }
    check(len(mysql.get_text(rows, 0, mysql.col(rows, "txt"))) == 3000, "text");
    check(mysql.get_bytes(rows, 0, mysql.col(rows, "bin")) == b"\x00\x01\xff", "varbinary keeps its bytes");
    check(mysql.get_bytes(rows, 0, mysql.col(rows, "blb")) == b"blob\x00data", "blob keeps its NUL");
    check(mysql.get_int(rows, 0, mysql.col(rows, "bt")) == 2730, "bit");
    check(mysql.get_bool(rows, 0, mysql.col(rows, "flag")), "bool");
    check(mysql.get_float(rows, 0, mysql.col(rows, "d")) == 0.1, "double exact");
    let js = mysql.get_text(rows, 0, mysql.col(rows, "js"));
    check(strings.contains(js, "\"k\"") && strings.contains(js, "1"), "json " + js);
    let tr = mysql.get_time(rows, 0, mysql.col(rows, "dtt"));
    guard let t = tr else let e = err_of(tr) { panic(e); }
    check(t.rfc3339_nano() == "2024-02-29T13:14:15.123456Z", t.rfc3339_nano());
    let dr = mysql.get_decimal(rows, 0, mysql.col(rows, "dec_"));
    guard let d = dr else let e = err_of(dr) { panic(e); }
    check(decimal.format(d) == "1234567890123456.7891", "decimal exact");
    // NULLs
    run(c, "INSERT INTO t_types (id) VALUES (2)");
    let nr = q(c, "SELECT ti, s, blb, dtt FROM t_types WHERE id = ?", [mysql.arg_int(2)]);
    for k in 0..4 {
        check(mysql.is_null(nr, 0, k), "null " + to_str(k));
    }
    let nn = q(c, "SELECT ? IS NULL", [mysql.arg_null()]);
    check(mysql.get_int(nn, 0, 0) == 1, "a NULL parameter");
    // rows_as
    run(c, "DROP TABLE IF EXISTS things");
    run(c, "CREATE TABLE things (id INT PRIMARY KEY, name VARCHAR(50) NOT NULL, price DOUBLE NOT NULL, " +
           "active TINYINT(1) NOT NULL, note TEXT, data BLOB NOT NULL, made DATETIME(3) NOT NULL)");
    run(c, "INSERT INTO things VALUES (1, 'pen', 2.5, 1, NULL, x'00ff', '2024-01-02 03:04:05.678'), " +
           "(2, 'ink', 12, 0, 'blue', x'', '2023-12-31 23:59:59')");
    let tr2 = q(c, "SELECT id, name, price, active, note, data, made FROM things ORDER BY id", []);
    let things: result[[Thing], str] = mysql.rows_as(tr2);
    guard let ts = things else let e = err_of(things) { panic("rows_as: " + e); }
    check(len(ts) == 2 && ts[0].name == "pen" && ts[0].price == 2.5 && ts[0].active && (ts[0].note ?? "absent") == "absent", "rows_as row 1");
    check(ts[0].data == b"\x00\xff" && ts[0].made.rfc3339_nano() == "2024-01-02T03:04:05.678Z", "rows_as bytes and time");
    check(ts[1].id == 2 && !ts[1].active && (ts[1].note ?? "") == "blue" && len(ts[1].data) == 0, "rows_as row 2");
    let maps: result[[map[str]str], str] = mysql.rows_as(q(c, "SELECT name, CAST(price AS CHAR) AS p FROM things ORDER BY id", []));
    guard let ms = maps else let e = err_of(maps) { panic(e); }
    check(ms[1]["name"] == "ink", "rows_as maps");
    println("  types ok");
}

fn errors_and_tx(c: mysql.Conn) {
    run(c, "DROP TABLE IF EXISTS uniq");
    run(c, "CREATE TABLE uniq (k INT PRIMARY KEY) ENGINE=InnoDB");
    run(c, "INSERT INTO uniq VALUES (1)");
    let dup = mysql.query(c, "INSERT INTO uniq VALUES (?)", [mysql.arg_int(1)], soon());
    let e = err_of(dup);
    check(mysql.error_code(e) == 1062 && mysql.sqlstate(e) == "23000", e);
    check(mysql.usable(c), "a server error leaves the connection usable");
    check(strings.contains(err_of(mysql.query(c, "SELECT ?", [], soon())), "1 parameter(s), 0 given"), "arg count");
    check(mysql.error_code(err_of(mysql.query(c, "SELEC 1", [], soon()))) == 1064, "syntax error");
    // transactions
    run(c, "BEGIN");
    check(mysql.in_transaction(c), "in a transaction");
    q(c, "INSERT INTO uniq VALUES (?)", [mysql.arg_int(2)]);
    run(c, "ROLLBACK");
    check(!mysql.in_transaction(c), "rolled back");
    check(mysql.get_int(q(c, "SELECT COUNT(*) FROM uniq", []), 0, 0) == 1, "the rollback undid the insert");
    // exec runs several statements and counts what they changed
    let n = mysql.exec(c, "INSERT INTO uniq VALUES (10), (11); UPDATE uniq SET k = k + 100 WHERE k >= 10; SELECT 1", soon());
    check((n ?? -1) == 4, "exec affected " + to_str(n ?? -1));
    check(mysql.error_code(err_of(mysql.exec(c, "INSERT INTO uniq VALUES (1); SELECT 1", soon()))) == 1062,
          "exec stops at the failing statement");
    check(mysql.get_int(q(c, "SELECT 7", []), 0, 0) == 7, "usable after a failed multi-statement exec");
    let pr = mysql.ping(c, soon());
    guard let _p = pr else let pe = err_of(pr) { panic(pe); }
    println("  errors and transactions ok");
}

fn streaming(c: mysql.Conn) {
    // 100,000 rows from five digit tables (portable; no recursion limit)
    let digits = "(SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 " +
                 "UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)";
    let sr = mysql.stream(c, "SELECT 1 + a.d + 10 * b.d + 100 * c.d + 1000 * e.d + 10000 * f.d AS n, REPEAT('v', 20) FROM " +
                          digits + " a, " + digits + " b, " + digits + " c, " + digits + " e, " + digits + " f", [], soon());
    guard let rows = sr else let e = err_of(sr) { panic(e); }
    let count = 0;
    let sum = 0;
    while true {
        let nr = mysql.next_row(c, rows, soon());
        guard let more = nr else let e = err_of(nr) { panic(e); }
        if !more {
            break;
        }
        count += 1;
        sum += mysql.get_int(rows, 0, 0);
    }
    check(count == 100000 && sum == 5000050000, "streamed " + to_str(count));
    check(mysql.get_int(q(c, "SELECT 1", []), 0, 0) == 1, "free after the stream");
    let s2 = mysql.stream(c, "SELECT n FROM (SELECT 1 n UNION ALL SELECT 2 UNION ALL SELECT 3) x", [], soon());
    guard let r2 = s2 else let e = err_of(s2) { panic(e); }
    mysql.next_row(c, r2, soon());
    check(strings.contains(err_of(mysql.query(c, "SELECT 1", [], soon())), "busy"), "busy while streaming");
    mysql.stream_close(c, r2, soon());
    check(mysql.get_int(q(c, "SELECT 2", []), 0, 0) == 2, "free after stream_close");
    println("  streaming ok");
}

fn statements(url: str) {
    let sep = "?";
    if strings.contains(url, "?") {
        sep = "&";
    }
    let c = conn(url + sep + "statement_cache=4");
    for round in 0..3 {
        for k in 0..10 {
            let rows = q(c, "SELECT ? + " + to_str(k), [mysql.arg_int(round)]);
            check(mysql.get_int(rows, 0, 0) == round + k, "cached statement");
        }
    }
    run(c, "DROP TABLE IF EXISTS alter_me");
    run(c, "CREATE TABLE alter_me (a INT)");
    run(c, "INSERT INTO alter_me VALUES (1)");
    check(len(q(c, "SELECT * FROM alter_me", []).columns) == 1, "before");
    run(c, "ALTER TABLE alter_me ADD COLUMN b INT DEFAULT 5");
    let after = q(c, "SELECT * FROM alter_me", []);
    check(len(after.columns) == 2 && mysql.get_int(after, 0, 1) == 5, "a cached statement after ALTER TABLE");
    mysql.close(c);
    println("  statement cache ok");
}

fn big(c: mysql.Conn) {
    let n = 20 * 1048576;
    let blob = strings.bytes_zero(n);
    for k in 0..n {
        blob[k] = (k * 31) & 255;
    }
    run(c, "DROP TABLE IF EXISTS bigrow");
    run(c, "CREATE TABLE bigrow (b LONGBLOB)");
    q(c, "INSERT INTO bigrow VALUES (?)", [mysql.arg_bytes(blob)]);
    let rows = q(c, "SELECT b, LENGTH(b) FROM bigrow", []);
    check(mysql.get_int(rows, 0, 1) == n && mysql.get_bytes(rows, 0, 0) == blob, "a 20 MiB value both ways");
    println("  20 MiB packets ok");
}

fn timeout_kills(url: str, admin: mysql.Conn) {
    let c = conn(url);
    let id = mysql.connection_id(c);
    let r = mysql.query(c, "SELECT SLEEP(20)", [], until_of(time.mono() + 300000000));
    check(err_of(r) == "timeout", "timeout: " + err_of(r));
    check(!mysql.usable(c), "broken after a timeout");
    // the statement is killed from a second connection, not left running
    let gone = false;
    for k in 0..50 {
        time.sleep(100000000);
        let pl = q(admin, "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE ID = ? AND INFO LIKE 'SELECT SLEEP%'",
                   [mysql.arg_int(id)]);
        if mysql.get_int(pl, 0, 0) == 0 {
            gone = true;
            break;
        }
    }
    check(gone, "the timed-out statement was killed");
    println("  timeout ok");
}

fn worker(p: mysql.Pool, id: int, done: chan[int]) {
    let good = 0;
    for k in 0..25 {
        let r = mysql.pool_query(p, "SELECT ? * 2", [mysql.arg_int(id * 100 + k)], soon());
        guard let rows = r else { continue; }
        if mysql.get_int(rows, 0, 0) == (id * 100 + k) * 2 {
            good += 1;
        }
    }
    chan_send(done, good);
}

fn pool(url: str) {
    let pr = mysql.new_pool(url, 6);
    guard let p = pr else let e = err_of(pr) { panic(e); }
    let done: chan[int] = make_chan(32);
    for t in 0..32 {
        spawn worker(p, t, done);
    }
    let total = 0;
    for t in 0..32 {
        total += chan_recv(done) ?? 0;
    }
    check(total == 800, "pool: " + to_str(total) + " of 800");
    check(p.dials <= 6, "at most max_open connections");
    // a released transaction is not handed to the next caller
    let ar = mysql.acquire(p, soon());
    guard let c = ar else let e = err_of(ar) { panic(e); }
    run(c, "BEGIN");
    mysql.release(p, c);
    check(p.open <= 6, "open count");
    mysql.pool_close(p);
    println("  pool ok");
}

fn suite(label: str, url: str, maria: bool) {
    println(label + ":");
    let c = conn(url);
    println("  server " + mysql.server_version(c));
    types(c, maria);
    errors_and_tx(c);
    streaming(c);
    if !maria {
        big(c);
    }
    statements(url);
    timeout_kills(url, c);
    pool(url);
    mysql.close(c);
}

fn auth_only(label: str, url: str) {
    let c = conn(url);
    check(mysql.get_int(q(c, "SELECT 1", []), 0, 0) == 1, label);
    mysql.close(c);
    println(label + ": ok");
}

let main_url = proc.getenv("MYSQL_URL") ?? "";
if main_url != "" {
    suite("mysql", main_url, false);
}
for name in ["MYSQL_NATIVE_URL", "MYSQL_SHA2_URL", "MYSQL_SHA256_URL"] {
    let u = proc.getenv(name) ?? "";
    if u != "" {
        auth_only(name, u);
    }
}
let maria_url = proc.getenv("MARIADB_URL") ?? "";
if maria_url != "" {
    suite("mariadb", maria_url, true);
}
println("done");
