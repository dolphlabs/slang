// `c.split()`: one connection read by one task and written by another.
// The point is a write from outside the reading task while that task is
// parked in recv -- a server pushing to a client that has sent nothing --
// over plain TCP and over TLS, where both halves share one session.
//
// Also: the halves keep to their roles, the reader's end closes the
// connection for both, the writer's end leaves the reader working, and
// heavy traffic in both directions at once keeps every byte in order.

import "net";
import "time";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn soon(ms: int) -> until {
    return until_of(time.mono() + ms * 1000000);
}

// The writer's task: every message from `out`, in order, until it closes.
fn writer(w: link, out: chan[bytes], done: chan[str]) {
    let mut_w = w;
    while true {
        let m = chan_recv(out);
        guard let b = m else { break; }
        let sr = mut_w.send_bytes(b, soon(5000));
        guard let _n = sr else let e = err_of(sr) {
            chan_send(done, "writer: " + to_str(e));
            return;
        }
    }
    chan_send(done, "writer done");
}

// Reads one line-ish message into a string (whatever one recv returns).
fn recv_str(c: &mut link, ms: int) -> str {
    let a = arena_new(4096);
    let w = a.wire(4096);
    let rr = c.recv(w, soon(ms));
    guard let n = rr else let e = err_of(rr) { return "recv: " + to_str(e); }
    if n == 0 { return "eof"; }
    let out = b"";
    let i = 0;
    while i < n {
        let one = b".";
        one[0] = w[i];
        out = out + one;
        i = i + 1;
    }
    return to_str(out);
}

// ---- plain TCP --------------------------------------------------------

fn plain_server(ln: link, ready: chan[str], done: chan[str]) {
    let mut_ln = ln;
    let ar = mut_ln.accept(soon(5000));
    guard let c = ar else { chan_send(ready, "accept"); return; }
    let sr = c.split();
    guard let w = sr else let e = err_of(sr) { chan_send(ready, "split: " + to_str(e)); return; }
    let again = c.split();
    if let _x = again { chan_send(ready, "split twice worked"); return; }
    else let e2 = err_of(again) { println(to_str(e2)); }
    let wrong = c.send_bytes(b"x", soon(1000));
    if let _x = wrong { chan_send(ready, "reader sent"); return; }
    else let e3 = err_of(wrong) { println(to_str(e3)); }
    let out: chan[bytes] = make_chan(16);
    let wdone: chan[str] = make_chan(1);
    spawn writer(w, out, wdone);
    chan_send(ready, "ready");
    // parked here, with nothing sent yet, while the writer pushes
    let got = recv_str(&mut c, 5000);
    chan_send(out, to_bytes("echo " + got));
    chan_close(out);
    // stays open until the writer has sent the echo, then returns: the
    // reader's end closes the connection
    let wd = chan_recv(wdone) ?? "";
    chan_send(done, wd);
}

fn scenario_plain() {
    let lr = link_listen(0, 1);
    guard let ln = lr else { die("listen"); }
    let port = ln.port();
    let ready: chan[str] = make_chan(1);
    let done: chan[str] = make_chan(4);
    spawn plain_server(ln, ready, done);
    let dr = link_dial("127.0.0.1", port, soon(5000));
    guard let cl = dr else { die("dial"); }
    let r = chan_recv(ready) ?? "no answer";
    if r != "ready" { die(r); }
    let _s = cl.send_bytes(b"hello", soon(5000));
    println("client got: " + recv_str(&mut cl, 5000));
    println("server: " + (chan_recv(done) ?? "no answer"));
    println("then: " + recv_str(&mut cl, 5000));
}

// The writer pushes on a timer while the reader waits for a client that
// says nothing until it has seen three pushes.
fn ticker(out: chan[bytes]) {
    let i = 1;
    while i <= 3 {
        time.sleep(20000000);
        chan_send(out, to_bytes("tick " + to_str(i) + ";"));
        i = i + 1;
    }
}

fn push_server(ln: link, ctx: rawptr, tls: bool, done: chan[str]) {
    let mut_ln = ln;
    let ar = mut_ln.accept(soon(5000));
    guard let c = ar else { chan_send(done, "accept"); return; }
    if tls {
        let hr = c.tls_accept(ctx, soon(5000));
        guard let _h = hr else let e = err_of(hr) { chan_send(done, "handshake: " + to_str(e)); return; }
    }
    let sr = c.split();
    guard let w = sr else let e = err_of(sr) { chan_send(done, "split: " + to_str(e)); return; }
    if tls {
        let late = c.tls_accept(ctx, soon(1000));
        if let _x = late { chan_send(done, "tls_accept after split worked"); return; }
    }
    let wa = arena_new(16);
    let wrong = w.recv(wa.wire(16), soon(1000));
    if let _x = wrong { chan_send(done, "writer read"); return; }
    else let e2 = err_of(wrong) { println(to_str(e2)); }
    let out: chan[bytes] = make_chan(16);
    let wdone: chan[str] = make_chan(1);
    spawn writer(w, out, wdone);
    spawn ticker(out);
    let got = recv_str(&mut c, 5000);
    chan_send(done, "server read " + got);
    // returns now: the reader's end closes the connection, with the
    // writer still holding its half
    let _w = wdone;
}

fn scenario_push(tls: bool, ctx: rawptr, cctx: rawptr) {
    let lr = link_listen(0, 1);
    guard let ln = lr else { die("listen"); }
    let port = ln.port();
    let done: chan[str] = make_chan(4);
    spawn push_server(ln, ctx, tls, done);
    let label = "plain";
    if tls { label = "tls"; }
    let seen = "";
    if tls {
        let dr: result[rawptr, str] = net.tls_dial("localhost", port, cctx);
        guard let cc = dr else let e = err_of(dr) { die("tls dial: " + e); }
        while len(seen) < 21 {
            let rr: result[bytes, str] = net.tls_recv_until(cc, 64, soon(5000));
            guard let b = rr else { die("tls client recv"); }
            if len(b) == 0 { die("tls early eof"); }
            seen = seen + to_str(b);
        }
        net.tls_send(cc, b"seen them");
        println(label + " pushed while the reader waited: " + seen);
        println(label + " " + (chan_recv(done) ?? "no answer"));
        let er: result[bytes, str] = net.tls_recv_until(cc, 64, soon(5000));
        if let b2 = er {
            println(label + " after the reader ended: " + to_str(len(b2)) + " bytes");
        } else {
            println(label + " after the reader ended: closed");
        }
        net.tls_close(cc);
        return;
    }
    let dr = link_dial("127.0.0.1", port, soon(5000));
    guard let cl = dr else { die("dial"); }
    while len(seen) < 21 {
        let s = recv_str(&mut cl, 5000);
        if s == "eof" { die("early eof"); }
        seen = seen + s;
    }
    let _s = cl.send_bytes(b"seen them", soon(5000));
    println(label + " pushed while the reader waited: " + seen);
    println(label + " " + (chan_recv(done) ?? "no answer"));
    println(label + " after the reader ended: " + recv_str(&mut cl, 5000));
}

// The writer's end first: the reader keeps reading.
fn writer_first_server(ln: link, done: chan[str]) {
    let mut_ln = ln;
    let ar = mut_ln.accept(soon(5000));
    guard let c = ar else { chan_send(done, "accept"); return; }
    let sr = c.split();
    guard let w = sr else { chan_send(done, "split"); return; }
    drop(w);
    chan_send(done, "writer dropped");
    chan_send(done, "reader read " + recv_str(&mut c, 5000));
}

fn drop(c: link) {
    let _p = c.port();
}

fn scenario_writer_first() {
    let lr = link_listen(0, 1);
    guard let ln = lr else { die("listen"); }
    let port = ln.port();
    let done: chan[str] = make_chan(4);
    spawn writer_first_server(ln, done);
    let dr = link_dial("127.0.0.1", port, soon(5000));
    guard let cl = dr else { die("dial"); }
    println(chan_recv(done) ?? "no answer");
    let _s = cl.send_bytes(b"still here", soon(5000));
    println(chan_recv(done) ?? "no answer");
}

// Both directions at full speed over one TLS session: the reader drains
// 2,000 client messages while the writer sends 2,000 of its own.
fn busy_server(ln: link, ctx: rawptr, done: chan[str]) {
    let mut_ln = ln;
    let ar = mut_ln.accept(soon(5000));
    guard let c = ar else { chan_send(done, "accept"); return; }
    let hr = c.tls_accept(ctx, soon(5000));
    guard let _h = hr else { chan_send(done, "handshake"); return; }
    let sr = c.split();
    guard let w = sr else { chan_send(done, "split"); return; }
    let out: chan[bytes] = make_chan(64);
    let wdone: chan[str] = make_chan(1);
    spawn writer(w, out, wdone);
    spawn flood(out, 2000);
    let a = arena_new(65536);
    let buf = a.wire(65536);
    let total = 0;
    let bad = 0;
    while total < 2000 * 8 {
        let rr = c.recv(buf, soon(10000));
        guard let n = rr else let e = err_of(rr) { chan_send(done, "recv: " + to_str(e)); return; }
        if n == 0 { chan_send(done, "eof at " + to_str(total)); return; }
        let i = 0;
        while i < n {
            // the client sends "c0000000".."c0001999" style 8-byte records;
            // checking the first byte of each is enough to see interleaving
            if (total + i) % 8 == 0 && buf[i] != 99 { bad = bad + 1; }
            i = i + 1;
        }
        total = total + n;
    }
    chan_send(done, "server read " + to_str(total) + " bytes, misaligned " + to_str(bad) +
              ", " + (chan_recv(wdone) ?? "writer?"));
}

fn record(tag: str, i: int) -> bytes {
    let s = to_str(i);
    while len(s) < 7 { s = "0" + s; }
    return to_bytes(tag + s);
}

fn flood(out: chan[bytes], n: int) {
    let i = 0;
    while i < n {
        chan_send(out, record("s", i));
        i = i + 1;
    }
    chan_close(out);
}

fn scenario_busy(ctx: rawptr, cctx: rawptr) {
    let lr = link_listen(0, 1);
    guard let ln = lr else { die("listen"); }
    let port = ln.port();
    let done: chan[str] = make_chan(4);
    spawn busy_server(ln, ctx, done);
    let dr: result[rawptr, str] = net.tls_dial("localhost", port, cctx);
    guard let cc = dr else { die("dial"); }
    let i = 0;
    let got = b"";
    while i < 2000 {
        net.tls_send(cc, record("c", i));
        i = i + 1;
    }
    while len(got) < 2000 * 8 {
        let rr: result[bytes, str] = net.tls_recv_until(cc, 65536, soon(10000));
        guard let b = rr else { die("busy client recv"); }
        if len(b) == 0 { die("busy client eof"); }
        got = got + b;
    }
    let in_order = true;
    let k = 0;
    while k < 2000 {
        if got[k * 8..k * 8 + 8] != record("s", k) { in_order = false; }
        k = k + 1;
    }
    println("tls both ways: client got 16000 bytes in order=" + to_str(in_order));
    println(chan_recv(done) ?? "no answer");
    net.tls_close(cc);
}

let sctx_r: result[rawptr, str] = net.tls_server_ctx("tests/tls/cert.pem", "tests/tls/key.pem");
guard let sctx = sctx_r else { die("server ctx"); }
let cctx_r: result[rawptr, str] = net.tls_client_ctx("tests/tls/cert.pem");
guard let cctx = cctx_r else { die("client ctx"); }

scenario_plain();
scenario_push(false, sctx, cctx);
scenario_push(true, sctx, cctx);
scenario_writer_first();
scenario_busy(sctx, cctx);
