fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn run() {
    let lr = link_listen(0);
    guard let ln = lr else { die("listen"); }
    let port = ln.port();
    if port <= 0 || port >= 65536 { die("port"); }

    let dr = link_dial("127.0.0.1", port, until_never());
    guard let c = dr else { die("dial"); }

    let a = arena_new(256);
    let w = a.wire(4);
    w[0] = 80;
    w[1] = 73;
    w[2] = 78;
    w[3] = 71;
    let sr = c.send(w, until_never());
    guard let n = sr else { die("send"); }
    if n != 4 { die("send length"); }
    println("sent 4 bytes");

    let br = c.send_bytes(b"PING", until_never());
    guard let bn = br else { die("send_bytes"); }
    if bn != 4 { die("send_bytes length"); }
    println("sent bytes 4");

    let ar = ln.accept(until_never());
    guard let s = ar else { die("accept"); }

    let buf = a.wire(64);
    let rr = s.recv(buf, until_never());
    guard let got = rr else { die("recv"); }
    if got != 4 { die("recv length"); }
    if buf[0] != 80 || buf[1] != 73 || buf[2] != 78 || buf[3] != 71 {
        die("payload");
    }
    println("echo payload ok");

    let buf2 = a.wire(64);
    let rr2 = s.recv(buf2, until_never());
    guard let got2 = rr2 else { die("recv2"); }
    if got2 != 4 { die("recv2 length"); }
    if buf2[0] != 80 || buf2[1] != 73 || buf2[2] != 78 || buf2[3] != 71 {
        die("payload2");
    }
    println("echo bytes ok");

    let p = s.peer();
    if peer_port(p) <= 0 { die("peer"); }
    println("link ok");
}

run();
