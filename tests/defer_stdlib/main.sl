import "sql";
import "http";
import "httpc";
import "strings";

gc struct Trash {
    pad: str,
}

fn churn_gc(n: int) {
    for i in 0..n {
        let _ = Trash { pad: strings.repeat("g", 24) + to_str(i) };
    }
}

fn test_sql_defer() -> int {
    let dr = sql.open(":memory:");
    guard let db = dr else |e| {
        println("FAIL sql open: " + e);
        exit(1);
    }
    defer sql.close(db);

    let cr = sql.exec(db, "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)");
    guard let _c = cr else |e| {
        println("FAIL sql create: " + e);
        exit(1);
    }

    let ir = sql.prepare(db, "INSERT INTO items (name) VALUES (?)");
    guard let ins = ir else |e| {
        println("FAIL sql prepare ins: " + e);
        exit(1);
    }
    defer sql.finalize(ins);

    let _ = sql.bind_text(ins, 1, "alpha");
    let sr = sql.step(ins);
    guard let _s = sr else |e| {
        println("FAIL sql step: " + e);
        exit(1);
    }

    let qr = sql.prepare(db, "SELECT name FROM items WHERE id = 1");
    guard let sel = qr else |e| {
        println("FAIL sql prepare sel: " + e);
        exit(1);
    }
    defer sql.finalize(sel);

    let s2 = sql.step(sel);
    guard let has_row = s2 else |e| {
        println("FAIL sql sel step: " + e);
        exit(1);
    }
    if !has_row {
        println("FAIL sql missing row");
        exit(1);
    }
    let name = sql.col_text(sel, 0);
    churn_gc(300);
    println("sql_name=" + name);
    return len(name);
}

fn serve_deferred_http(ln: link) {
    let ar = ln.accept(until_never());
    guard let conn = ar else {
        println("FAIL accept");
        exit(1);
    }
    let a = arena_new(4096);
    let buf = a.wire(1024);
    let rr = http.read(&mut conn, buf, 0, until_never());
    guard let got = rr else |e| {
        println("FAIL http read: " + e);
        exit(1);
    }
    let resp = http.Response {
        status: 200 as i32,
        status_text: "OK",
        content_type: "text/plain",
        location: "",
        extra: [],
        body: to_bytes("deferred:" + got.req.method),
    };
    defer http.write(&mut conn, resp, &mut a, until_never());
    churn_gc(300);
}

fn test_http_and_httpc_defer() {
    let lr = link_listen(0);
    guard let ln = lr else {
        println("FAIL listen");
        exit(1);
    }
    let port = ln.port();
    spawn serve_deferred_http(ln);

    let cl = httpc.new_client();
    defer cl.close_idle();

    let url = "http://127.0.0.1:" + to_str(port) + "/ping";
    let res = cl.get(url, until_never());
    guard let resp = res else |e| {
        println("FAIL httpc get: " + e);
        exit(1);
    }
    churn_gc(300);
    println("http_status=" + to_str(resp.status) + " body=" + to_str(resp.body));
}

println("sql_len=" + to_str(test_sql_defer()));
test_http_and_httpc_defer();
