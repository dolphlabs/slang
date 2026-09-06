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

fn serialize_ok() {
    let r = http.ok_text("hi");
    let out = http.serialize(r);
    if out != to_bytes("HTTP/1.1 200 OK\r\ncontent-type: text/plain; charset=utf-8\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi") {
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
    let rr = http.read(&mut s, buf, until_never());
    guard let got = rr else { die("read"); }
    if got.method != "POST" { die("read method"); }
    if got.path != "/echo" { die("read path"); }
    if got.body != b"xyz" { die("read body"); }
    let host = http.header(got, "host");
    guard let hv = host else { die("read host"); }
    if hv != "t" { die("read host value"); }

    let wr = http.write(&mut s, http.ok_text("ok"), &mut a, until_never());
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

parse_get();
parse_post();
parse_errors();
serialize_ok();
loopback();
println("http ok");
