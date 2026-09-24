import "http";

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

fn parse_get() {
    let raw = to_bytes("GET /hi HTTP/1.1\r\nHost: t\r\nX-A: B\r\n\r\n");
    let pr = http.parse(raw);
    guard let req = pr else { die("parse get"); }
    if req.method != "GET" { die("method"); }
    if req.path != "/hi" { die("path"); }
    if len(req.body) != 0 { die("empty body"); }
    let host = http.header(req, "HOST");
    guard let h = host else { die("host"); }
    if h != "t" { die("host value"); }
    let xa = http.header(req, "x-a");
    guard let v = xa else { die("x-a"); }
    if v != "B" { die("x-a value"); }
    println("parse get");
}

fn parse_post() {
    let raw = to_bytes("POST /x HTTP/1.0\r\nContent-Length: 5\r\n\r\nhelloTRAIL");
    let pr = http.parse(raw);
    guard let req = pr else { die("parse post"); }
    if req.method != "POST" { die("post method"); }
    if req.path != "/x" { die("post path"); }
    if req.body != b"hello" { die("post body"); }
    println("parse post");
}

fn expect_err(r: result[http.Request, str], label: str) {
    guard let _v = r else {
        println(label);
        return;
    }
    die(label + " should fail");
}

fn parse_errors() {
    expect_err(http.parse(b""), "empty");
    expect_err(http.parse(to_bytes("GET / HTTP/2.0\r\n\r\n")), "version");
    expect_err(http.parse(to_bytes("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")),
               "chunked");
    expect_err(http.parse(to_bytes("POST / HTTP/1.1\r\nContent-Length: 4\r\n\r\nab")),
               "truncated");
}

fn frame_parity() {
    let cases = [
        "GET /hi HTTP/1.1\r\nHost: t\r\nX-A: B\r\n\r\n",
        "GET /users/42 HTTP/1.1\r\nHost: t\r\nUser-Agent: bench\r\nAccept: */*\r\n\r\n",
        "POST /x HTTP/1.0\r\nContent-Length: 5\r\n\r\nhelloTRAIL",
        "POST /up HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
        "GET /a HTTP/1.1\r\nHost: t\r\n\r\nGET /b HTTP/1.1\r\nHost: t\r\n\r\n"
    ];
    let ci = 0;
    while ci < len(cases) {
        let raw = to_bytes(cases[ci]);
        let pr = parse(raw);
        guard let want = pr else let e = err_of(pr) {
            die("parity parse case " + to_str(ci) + ": " + e);
        }
        let fr = parse_frame(raw);
        guard let got = fr else let e = err_of(fr) {
            die("parity frame case " + to_str(ci) + ": " + e);
        }
        if !method_is(raw, got, want.method) {
            die("parity method case " + to_str(ci));
        }
        if !path_is(raw, got, want.path) {
            die("parity path case " + to_str(ci));
        }
        if frame_version(got) != version_flag(want.version) {
            die("parity version case " + to_str(ci));
        }
        if frame_body(raw, got) != want.body {
            die("parity body case " + to_str(ci));
        }
        ci = ci + 1;
    }
    // error parity: every corpus parse() rejects, parse_frame rejects too
    let bad = [
        b"",
        to_bytes("GET / HTTP/2.0\r\n\r\n"),
        to_bytes("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"),
        to_bytes("POST / HTTP/1.1\r\nContent-Length: 4\r\n\r\nab")
    ];
    let bi = 0;
    while bi < len(bad) {
        let fr = parse_frame(bad[bi]);
        guard let _g = fr else {
            bi = bi + 1;
            continue;
        }
        die("parity accepted bad case " + to_str(bi));
    }
    println("frame parity");
}

fn version_flag(v: str) -> int {
    if v == "HTTP/1.0" {
        return 0;
    }
    return 1;
}

fn serialize_ok() {
    let r = http.ok_text("hi");
    let out = http.serialize(r);
    if out != to_bytes("HTTP/1.1 200 OK\r\ncontent-type: text/plain; charset=utf-8\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nhi") {
        die("serialize");
    }
    println("serialize");
}

fn loopback() {
    let lr = link_listen(0);
    guard let ln = lr else { die("listen"); }
    let port = ln.port();
    let dr = link_dial("127.0.0.1", port, until_never());
    guard let c = dr else { die("dial"); }

    let a = arena_new(2048);
    let req = to_bytes("POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 3\r\n\r\nxyz");
    let out = a.wire(len(req));
    fill(out, req);
    let sr = c.send(out, until_never());
    guard let _n = sr else { die("send"); }

    let ar = ln.accept(until_never());
    guard let s = ar else { die("accept"); }
    let buf = a.wire(512);
    let rr = http.read(&mut s, buf, 0, until_never());
    guard let got = rr else { die("read"); }
    if got.req.method != "POST" { die("read method"); }
    if got.req.path != "/echo" { die("read path"); }
    if got.req.body != b"xyz" { die("read body"); }
    if got.filled != 0 { die("no leftover"); }
    let host = http.header(got.req, "host");
    guard let hv = host else { die("read host"); }
    if hv != "t" { die("read host value"); }

    let sa = arena_new(256);
    let wr = http.write(&mut s, http.ok_text("ok"), &mut sa, until_never());
    guard let wn = wr else { die("write"); }
    if wn <= 0 { die("write len"); }

    let inb = a.wire(256);
    let cr = c.recv(inb, until_never());
    guard let cn = cr else { die("client recv"); }
    let resp = http.parse(to_bytes("GET / HTTP/1.1\r\n\r\n"));
    guard let _ignore = resp else { die("keep parse alive"); }
    if cn < 16 { die("client short"); }
    if inb[0] != 72 || inb[1] != 84 || inb[2] != 84 || inb[3] != 80 {
        die("resp magic");
    }
    println("loopback");
}

fn keepalive() {
    let lr = link_listen(0);
    guard let ln = lr else { die("ka listen"); }
    let port = ln.port();
    let dr = link_dial("127.0.0.1", port, until_never());
    guard let c = dr else { die("ka dial"); }

    let a = arena_new(2048);
    let req = to_bytes("GET /a HTTP/1.1\r\nHost: t\r\n\r\nGET /b HTTP/1.1\r\nHost: t\r\n\r\n");
    let out = a.wire(len(req));
    fill(out, req);
    let sr = c.send(out, until_never());
    guard let _n = sr else { die("ka send"); }

    let ar = ln.accept(until_never());
    guard let s = ar else { die("ka accept"); }
    let buf = a.wire(512);
    let r1 = http.read(&mut s, buf, 0, until_never());
    guard let first = r1 else { die("ka read1"); }
    if first.req.path != "/a" { die("ka path a"); }
    if http.wants_close(first.req) { die("ka close a"); }
    if first.filled <= 0 { die("ka leftover"); }

    let r2 = http.read(&mut s, buf, first.filled, until_never());
    guard let second = r2 else { die("ka read2"); }
    if second.req.path != "/b" { die("ka path b"); }
    if second.filled != 0 { die("ka leftover2"); }
    println("keepalive");
}

parse_get();
parse_post();
parse_errors();
frame_parity();
serialize_ok();
loopback();
keepalive();
println("http ok");
