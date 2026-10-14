// TLS on a `link`: `c.tls_accept(ctx, deadline)` runs the server
// handshake on an accepted link, and from then on everything built on
// the link -- here http.read_frame and http.write -- speaks TLS without
// knowing it. The client side is net.tls_dial, a separate implementation,
// so a link that only agreed with itself would not pass.
//
// Also covered: a body larger than one TLS record (16 KB) read in many
// small recvs, a client that speaks plaintext, a handshake that never
// starts (the deadline), a second tls_accept on the same link, and the
// fault each failure comes back as.

import "http";
import "net";
import "strings";
import "time";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn soon(ms: int) -> until {
    return until_of(time.mono() + ms * 1000000);
}

fn server_ctx() -> rawptr {
    let r: result[rawptr, str] = net.tls_server_ctx("tests/tls/cert.pem",
                                                    "tests/tls/key.pem");
    guard let ctx = r else { die("server ctx"); }
    return ctx;
}

fn client_ctx() -> rawptr {
    let r: result[rawptr, str] = net.tls_client_ctx("tests/tls/cert.pem");
    guard let ctx = r else { die("client ctx"); }
    return ctx;
}

// One HTTP request over TLS: framed by read_frame, answered by write.
fn http_server(ln: link, ctx: rawptr, done: chan[str]) {
    let mut_ln = ln;
    let ar = mut_ln.accept(soon(5000));
    guard let c = ar else { chan_send(done, "accept"); return; }
    let hr = c.tls_accept(ctx, soon(5000));
    guard let _h = hr else let e = err_of(hr) {
        chan_send(done, "handshake: " + to_str(e));
        return;
    }
    let again = c.tls_accept(ctx, soon(5000));
    if let _x = again {
        chan_send(done, "second tls_accept succeeded");
        return;
    } else let e2 = err_of(again) {
        println("second tls_accept: " + to_str(e2));
    }
    let a = arena_new(4096);
    let buf = a.wire(4096);
    let fr = http.read_frame(&mut c, buf, 0, soon(5000), soon(5000), soon(5000));
    guard let f = fr else let fe = err_of(fr) {
        chan_send(done, "read_frame: " + fe);
        return;
    }
    let sa = arena_new(4096);
    let resp = http.ok_text("hello over tls, " + f.method + " " + f.path);
    let wr = http.write(&mut c, resp, &mut sa, soon(5000));
    guard let _w = wr else { chan_send(done, "write"); return; }
    chan_send(done, "ok");
}

fn scenario_http(ctx: rawptr, cctx: rawptr) {
    let lr = link_listen(0, 1);
    guard let ln = lr else { die("listen"); }
    let port = ln.port();
    let done: chan[str] = make_chan(1);
    spawn http_server(ln, ctx, done);
    let dr: result[rawptr, str] = net.tls_dial("localhost", port, cctx);
    guard let cc = dr else let e = err_of(dr) { die("dial: " + e); }
    net.tls_send(cc, b"GET /tls HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    let got = b"";
    while true {
        let rr: result[bytes, str] = net.tls_recv(cc, 4096);
        guard let chunk = rr else { break; }
        if len(chunk) == 0 { break; }
        got = got + chunk;
    }
    net.tls_close(cc);
    let s = chan_recv(done) ?? "no answer";
    if s != "ok" { die(s); }
    let text = to_str(got);
    if !strings.contains(text, "200 OK") { die("status: " + text); }
    if !strings.contains(text, "hello over tls, GET /tls") { die("body: " + text); }
    println("http over a tls link ok");
}

// Echoes 100 KB back: more than six TLS records each way, read into a
// 1000-byte wire so every record takes several recvs.
fn echo_server(ln: link, ctx: rawptr, done: chan[str]) {
    let mut_ln = ln;
    let ar = mut_ln.accept(soon(5000));
    guard let c = ar else { chan_send(done, "accept"); return; }
    let hr = c.tls_accept(ctx, soon(5000));
    guard let _h = hr else { chan_send(done, "handshake"); return; }
    let a = arena_new(1024);
    let w = a.wire(1000);
    let total = 0;
    while total < 100000 {
        let rr = c.recv(w, soon(5000));
        guard let n = rr else let e = err_of(rr) {
            chan_send(done, "recv: " + to_str(e));
            return;
        }
        if n == 0 { chan_send(done, "early eof"); return; }
        let sr = c.send(w[0..n], soon(5000));
        guard let _s = sr else { chan_send(done, "send"); return; }
        total = total + n;
    }
    // the client has hung up by now: end of stream is a zero-byte read
    let er = c.recv(w, soon(5000));
    guard let z = er else let e = err_of(er) {
        chan_send(done, "eof: " + to_str(e));
        return;
    }
    chan_send(done, "ok, then read " + to_str(z));
}

fn scenario_large(ctx: rawptr, cctx: rawptr) {
    let lr = link_listen(0, 1);
    guard let ln = lr else { die("listen"); }
    let port = ln.port();
    let done: chan[str] = make_chan(1);
    spawn echo_server(ln, ctx, done);
    let dr: result[rawptr, str] = net.tls_dial("localhost", port, cctx);
    guard let cc = dr else { die("dial"); }
    let block = b"";
    let i = 0;
    while i < 1000 {
        block = block + to_bytes("0123456789");
        i = i + 1;
    }
    let sent = 0;
    while sent < 100000 {
        net.tls_send(cc, block);
        sent = sent + len(block);
    }
    let got = 0;
    let same = true;
    while got < 100000 {
        let rr: result[bytes, str] = net.tls_recv(cc, 65536);
        guard let chunk = rr else { die("client recv"); }
        if len(chunk) == 0 { die("client eof"); }
        let k = 0;
        while k < len(chunk) {
            if chunk[k] != 48 + ((got + k) % 10) { same = false; }
            k = k + 1;
        }
        got = got + len(chunk);
    }
    net.tls_close(cc);
    let s = chan_recv(done) ?? "no answer";
    println("echo 100000 bytes: same=" + to_str(same) + ", server " + s);
}

fn expect_failure(ln: link, ctx: rawptr, ms: int, done: chan[str]) {
    let mut_ln = ln;
    let ar = mut_ln.accept(soon(5000));
    guard let c = ar else { chan_send(done, "accept"); return; }
    let hr = c.tls_accept(ctx, soon(ms));
    if let _h = hr {
        chan_send(done, "handshake succeeded");
    } else let e = err_of(hr) {
        chan_send(done, to_str(e));
    }
}

fn scenario_plaintext(ctx: rawptr) {
    let lr = link_listen(0, 1);
    guard let ln = lr else { die("listen"); }
    let port = ln.port();
    let done: chan[str] = make_chan(1);
    spawn expect_failure(ln, ctx, 5000, done);
    let dr = link_dial("127.0.0.1", port, soon(5000));
    guard let c = dr else { die("dial"); }
    let _s = c.send_bytes(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n", soon(5000));
    println("plaintext client: " + (chan_recv(done) ?? "no answer"));
}

fn scenario_silent(ctx: rawptr) {
    let lr = link_listen(0, 1);
    guard let ln = lr else { die("listen"); }
    let port = ln.port();
    let done: chan[str] = make_chan(1);
    spawn expect_failure(ln, ctx, 100, done);
    let dr = link_dial("127.0.0.1", port, soon(5000));
    guard let _c = dr else { die("dial"); }
    println("silent client: " + (chan_recv(done) ?? "no answer"));
}

fn scenario_hangup(ctx: rawptr) {
    let lr = link_listen(0, 1);
    guard let ln = lr else { die("listen"); }
    let port = ln.port();
    let done: chan[str] = make_chan(1);
    spawn expect_failure(ln, ctx, 5000, done);
    let dr = link_dial("127.0.0.1", port, soon(5000));
    guard let c = dr else { die("dial"); }
    let _s = c.send_bytes(b"\x16\x03\x01", soon(5000));
    hang_up(c);
    println("client hung up mid-handshake: " + (chan_recv(done) ?? "no answer"));
}

fn hang_up(c: link) {
    // c is freed (closed) when this returns
    let _p = c.port();
}

let ctx = server_ctx();
let cctx = client_ctx();
scenario_http(ctx, cctx);
scenario_large(ctx, cctx);
scenario_plaintext(ctx);
scenario_silent(ctx);
scenario_hangup(ctx);
