// http.read / http.read_frame over a real socket: the socket path parses
// straight off the wire into one private WireHead, returning literals for
// the common methods and both versions and deciding Connection in place.
// Every case below goes through that path, not http.parse (the bytes
// path, tests/http_lazy_headers).
//
// ALLOC_BUDGET_N=N switches to the allocation-budget mode
// tests/run_tests.sh drives under SLANG_GC_STAT: N pipelined GETs through
// read + wants_close and nothing else, so the difference against N=0 is
// what one request costs.
import "http";
import "proc";

extern fn atoi(s: str) -> i32;

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn fill(dst: wire, src: bytes) {
    let i = 0;
    for b in src {
        dst[i] = b;
        i = i + 1;
    }
}

// Sends `raw` in one piece; the task ending closes the connection, which
// is how a reader waiting for more sees the end.
fn send_all(c: link, raw: bytes) {
    let a = arena_new(len(raw) + 64);
    if len(raw) > 0 {
        let w = a.wire(len(raw));
        fill(w, raw);
        let sr = c.send(w, until_never());
        guard let _n = sr else { return; }
    }
}

fn connect_pair(raw: bytes) -> link {
    let lr = link_listen(0);
    guard let ln = lr else { die("listen"); }
    let dr = link_dial("127.0.0.1", ln.port(), until_never());
    guard let c = dr else { die("dial"); }
    spawn send_all(c, raw);
    let ar = ln.accept(until_never());
    guard let s = ar else { die("accept"); }
    return s;
}

fn read_one(raw: str) -> result[http.Request, str] {
    let s = connect_pair(to_bytes(raw));
    let a = arena_new(4096);
    let buf = a.wire(1024);
    let r = http.read(&mut s, buf, 0, until_never());
    guard let got = r else let e = err_of(r) { return err(e); }
    return ok(got.req);
}

fn frame_one(raw: str) -> http.WireFrame {
    let s = connect_pair(to_bytes(raw));
    let a = arena_new(4096);
    let buf = a.wire(1024);
    let r = http.read_frame(&mut s, buf, 0, until_never(), until_never(),
                            until_never());
    guard let wf = r else let e = err_of(r) { die("read_frame: " + e); }
    return wf;
}

// The method comes back exactly as sent: a literal for the common ones,
// a copy for anything else -- including a lowercase spelling, since
// methods are case-sensitive and "get" is not GET.
fn methods() {
    let ms = ["GET", "PUT", "POST", "HEAD", "PATCH", "DELETE", "OPTIONS",
              "PURGE", "get", "GETX", "PUTS", "Post", "M"];
    for m in ms {
        let r = read_one(m + " /m HTTP/1.1\r\nHost: t\r\n\r\n");
        guard let req = r else let e = err_of(r) { die(m + ": " + e); }
        if req.method != m {
            die("method: got [" + req.method + "] want [" + m + "]");
        }
        if req.path != "/m" {
            die("method " + m + ": path [" + req.path + "]");
        }
    }
    println("methods");
}

fn versions() {
    let ok11 = read_one("GET / HTTP/1.1\r\n\r\n");
    guard let r11 = ok11 else let e = err_of(ok11) { die("1.1: " + e); }
    if r11.version != "HTTP/1.1" { die("1.1 version [" + r11.version + "]"); }
    let ok10 = read_one("GET / HTTP/1.0\r\n\r\n");
    guard let r10 = ok10 else let e = err_of(ok10) { die("1.0: " + e); }
    if r10.version != "HTTP/1.0" { die("1.0 version [" + r10.version + "]"); }
    let bad = ["HTTP/1.2", "HTTP/2.0", "http/1.1", "HTTP/1.10", "HTTP/1.",
               "HTTPS/1.1", "XTTP/1.1"];
    for v in bad {
        let r = read_one("GET / " + v + "\r\n\r\n");
        guard let _req = r else let e = err_of(r) {
            if e != "unsupported version" {
                die(v + ": error [" + e + "]");
            }
            continue;
        }
        die(v + ": accepted");
    }
    println("versions");
}

// wants_close (over the Request's copied header block) and read_frame's
// close flag (over the scan's in-place verdict) must agree on every case.
fn close_case(version: str, header: str, want: bool) {
    let raw = "GET / " + version + "\r\nHost: t\r\n" + header + "\r\n";
    let r = read_one(raw);
    guard let req = r else let e = err_of(r) { die("close case: " + e); }
    let what = version + " [" + header + "]";
    if http.wants_close(req) != want {
        die("wants_close " + what);
    }
    if frame_one(raw).close != want {
        die("read_frame close " + what);
    }
}

fn closes() {
    close_case("HTTP/1.1", "", false);
    close_case("HTTP/1.1", "Connection: close\r\n", true);
    close_case("HTTP/1.1", "connection:   CLOSE  \r\n", true);
    close_case("HTTP/1.1", "Connection: keep-alive\r\n", false);
    close_case("HTTP/1.1", "Connection: closed\r\n", false);
    close_case("HTTP/1.1", "Connection: close, upgrade\r\n", false);
    close_case("HTTP/1.1", "Connection:\r\n", false);
    close_case("HTTP/1.1", "Connection: keep-alive\r\nConnection: close\r\n",
               true);
    close_case("HTTP/1.0", "", true);
    close_case("HTTP/1.0", "Connection: Keep-Alive\r\n", false);
    close_case("HTTP/1.0", "Connection: keep-alive, upgrade\r\n", true);
    close_case("HTTP/1.0", "Connection: close\r\n", true);
    close_case("HTTP/1.0", "X-Connection: keep-alive\r\n", true);
    println("closes");
}

fn bodies() {
    let r0 = read_one("POST /b HTTP/1.1\r\nContent-Length: 0\r\n\r\n");
    guard let q0 = r0 else let e = err_of(r0) { die("cl 0: " + e); }
    if len(q0.body) != 0 { die("cl 0 body length"); }
    let r3 = read_one("POST /b HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc");
    guard let q3 = r3 else let e = err_of(r3) { die("cl 3: " + e); }
    if to_str(q3.body) != "abc" { die("cl 3 body [" + to_str(q3.body) + "]"); }
    let rc = read_one("POST /b HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" +
                      "2\r\nab\r\n1\r\nc\r\n0\r\n\r\n");
    guard let qc = rc else let e = err_of(rc) { die("chunked: " + e); }
    if to_str(qc.body) != "abc" { die("chunked body [" + to_str(qc.body) + "]"); }
    println("bodies");
}

// Two requests in one send: the first read hands back the second's bytes
// in `filled`, and the second read parses them without a recv -- the
// reused WireHead must not leak the first request into the second.
fn pipelined() {
    let s = connect_pair(to_bytes(
        "POST /one HTTP/1.1\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nhi" +
        "GET /two HTTP/1.0\r\n\r\n"));
    let a = arena_new(4096);
    let buf = a.wire(1024);
    let r1 = http.read(&mut s, buf, 0, until_never());
    guard let g1 = r1 else let e = err_of(r1) { die("pipelined 1: " + e); }
    if g1.req.method != "POST" || g1.req.path != "/one" ||
       to_str(g1.req.body) != "hi" || http.wants_close(g1.req) {
        die("pipelined 1 fields");
    }
    let r2 = http.read(&mut s, buf, g1.filled, until_never());
    guard let g2 = r2 else let e = err_of(r2) { die("pipelined 2: " + e); }
    if g2.req.method != "GET" || g2.req.path != "/two" ||
       g2.req.version != "HTTP/1.0" || len(g2.req.body) != 0 ||
       len(g2.req.raw_headers) != 0 || !http.wants_close(g2.req) {
        die("pipelined 2 fields");
    }
    println("pipelined");
}

// The budget's client: n copies of `one` laid out in a single arena wire
// and sent at once, so the client adds no GC allocations per request.
fn send_n(c: link, one: bytes, n: int) {
    if n == 0 {
        return;
    }
    let a = arena_new(n * len(one) + 64);
    let w = a.wire(n * len(one));
    let i = 0;
    while i < n {
        let j = 0;
        for b in one {
            w[i * len(one) + j] = b;
            j = j + 1;
        }
        i = i + 1;
    }
    let sr = c.send(w, until_never());
    guard let _n = sr else { return; }
}

fn budget(n: int) {
    let lr = link_listen(0);
    guard let ln = lr else { die("listen"); }
    let dr = link_dial("127.0.0.1", ln.port(), until_never());
    guard let c = dr else { die("dial"); }
    spawn send_n(c, to_bytes("GET /p HTTP/1.1\r\nHost: t\r\n\r\n"), n);
    let ar = ln.accept(until_never());
    guard let s = ar else { die("accept"); }
    let a = arena_new(8192);
    let buf = a.wire(4096);
    let filled = 0;
    let got = 0;
    while true {
        let r = http.read(&mut s, buf, filled, until_never());
        guard let g = r else { break; }
        if http.wants_close(g.req) { die("budget: close"); }
        filled = g.filled;
        got = got + 1;
    }
    if got != n { die("budget: read " + to_str(got) + " of " + to_str(n)); }
}

let reqs = proc.getenv("ALLOC_BUDGET_N");
guard let rs = reqs else {
    methods();
    versions();
    closes();
    bodies();
    pipelined();
    exit(0);
}
budget(atoi(rs));
