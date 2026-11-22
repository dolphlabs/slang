// net.send_file and net.tls_send_file: a file's bytes to a socket,
// whole or a range, checked byte for byte by a reader on the other end.
import "net";
import "fs";
import "time";
import "builder";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn soon() -> until { return until_of(time.mono() + 20000000000); }

// A position-dependent byte, so a range sent from the wrong offset or a
// chunk out of order changes the digest.
fn byte_at(i: int) -> u8 { return ((i * 7 + i / 251) % 256) as u8; }

fn digest(acc: int, b: bytes) -> int {
    let h = acc;
    for i in 0..len(b) {
        h = (h * 31 + (b[i] as int)) % 1000000007;
    }
    return h;
}

fn expect_digest(off: int, n: int) -> int {
    let h = 0;
    for i in off..off + n {
        h = (h * 31 + (byte_at(i) as int)) % 1000000007;
    }
    return h;
}

// Reads exactly n bytes and reports their digest, or -1.
fn reader(fd: int, n: int, out: chan[int]) {
    let h = 0;
    let got = 0;
    while got < n {
        let rr = net.recv_until(fd, 65536, soon());
        guard let b = rr else { chan_send(out, -1); return; }
        if len(b) == 0 { chan_send(out, -1); return; }
        h = digest(h, b);
        got = got + len(b);
    }
    chan_send(out, h);
}

fn tls_reader(ssl: rawptr, n: int, out: chan[int]) {
    let h = 0;
    let got = 0;
    while got < n {
        let rr = net.tls_recv_until(ssl, 65536, soon());
        guard let b = rr else { chan_send(out, -1); return; }
        if len(b) == 0 { chan_send(out, -1); return; }
        h = digest(h, b);
        got = got + len(b);
    }
    chan_send(out, h);
}

fn pair(lfd: int, port: int) -> [i32] {
    let cr = net.dial("127.0.0.1", port);
    guard let c = cr else { die("dial"); }
    let ar = net.accept(lfd);
    guard let s = ar else { die("accept"); }
    return [s, c];
}

fn run() {
    let path = "/tmp/sl_net_send_file.bin";
    let size = 3 * 1024 * 1024 + 123;
    let wr = fs.create(path);
    guard let wfd = wr else let we = err_of(wr) { die("create: " + we); }
    let chunk = 65536;
    let at = 0;
    while at < size {
        let n = chunk;
        if size - at < n { n = size - at; }
        let bb = builder.new_bytes();
        for i in 0..n { bb.write_byte(byte_at(at + i) as int); }
        let w = fs.write(wfd, bb.finish());
        guard let _w = w else { die("write"); }
        at = at + n;
    }
    fs.close(wfd);
    let orr = fs.open(path);
    guard let file = orr else { die("open"); }

    let lr = net.listen(0);
    guard let lfd = lr else { die("listen"); }
    let port = net.port(lfd) ?? 0;
    let out: chan[int] = make_chan(1);

    // 1. The whole file (count -1), larger than any socket buffer, so the
    //    send parks and resumes.
    let p1 = pair(lfd, port);
    spawn reader(p1[1], size, out);
    let s1 = net.send_file_until(p1[0], file, 0, -1, soon());
    guard let n1 = s1 else let e1 = err_of(s1) { die("whole file: " + e1); }
    if n1 != size { die("whole file sent " + to_str(n1)); }
    if (chan_recv(out) ?? -2) != expect_digest(0, size) { die("whole file digest"); }
    println("whole file: " + to_str(n1) + " bytes, digest ok");

    // 2. A range from an offset, and a count past the end (short).
    let s2 = net.send_file(p1[0], file, 1000, 5000);
    guard let n2 = s2 else { die("range"); }
    spawn reader(p1[1], 5000, out);
    if n2 != 5000 || (chan_recv(out) ?? -2) != expect_digest(1000, 5000) { die("range digest"); }
    let s3 = net.send_file(p1[0], file, size - 10, 100);
    guard let n3 = s3 else { die("short"); }
    spawn reader(p1[1], 10, out);
    if n3 != 10 || (chan_recv(out) ?? -2) != expect_digest(size - 10, 10) { die("short digest"); }
    let s4 = net.send_file(p1[0], file, size + 5, -1);
    guard let n4 = s4 else { die("past end"); }
    if n4 != 0 { die("past end sent " + to_str(n4)); }
    println("range, short and past-end: ok");

    // 3. Errors: an expired deadline, a negative offset, a socket that is
    //    not a file.
    let e5 = net.send_file_until(p1[0], file, 0, 10, until_of(time.mono()));
    if let _x = e5 { die("expired deadline sent"); } else let m5 = err_of(e5) { println("expired: " + m5); }
    let e6 = net.send_file(p1[0], file, -1, 10);
    if let _x6 = e6 { die("negative offset"); } else let m6 = err_of(e6) { println(m6); }
    let e7 = net.send_file(p1[0], p1[1], 0, -1);
    if let _x7 = e7 { die("socket as file"); } else let m7 = err_of(e7) { println(m7); }
    net.close(p1[0]);
    net.close(p1[1]);

    // 4. Over TLS.
    let scr = net.tls_server_ctx("tests/tls/cert.pem", "tests/tls/key.pem");
    guard let sctx = scr else let se = err_of(scr) { die("server ctx: " + se); }
    let ccr = net.tls_client_ctx("tests/tls/cert.pem");
    guard let cctx = ccr else { die("client ctx"); }
    let tl = net.listen(0);
    guard let tlfd = tl else { die("tls listen"); }
    let tport = net.port(tlfd) ?? 0;
    let acc: chan[rawptr] = make_chan(1);
    spawn accept_one(tlfd, sctx, acc);
    let dr = net.tls_dial("localhost", tport, cctx);
    guard let cssl = dr else let de = err_of(dr) { die("tls dial: " + de); }
    let ar = chan_recv(acc);
    guard let sssl = ar else { die("tls accept"); }
    spawn tls_reader(cssl, size - 7, out);
    let s8 = net.tls_send_file_until(sssl, file, 7, -1, soon());
    guard let n8 = s8 else let e8 = err_of(s8) { die("tls send_file: " + e8); }
    if n8 != size - 7 || (chan_recv(out) ?? -2) != expect_digest(7, size - 7) { die("tls digest"); }
    println("tls: " + to_str(n8) + " bytes, digest ok");
    net.tls_close(sssl);
    net.tls_close(cssl);
    fs.close(file);
    println("done");
}

fn accept_one(lfd: int, ctx: rawptr, out: chan[rawptr]) {
    let hr = net.tls_accept(lfd, ctx);
    guard let ssl = hr else let e = err_of(hr) { die("tls accept: " + e); }
    chan_send(out, ssl);
}

run();
