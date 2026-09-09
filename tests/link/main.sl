fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn run() {
    let lr = link_listen(0, 1);
    guard let ln = lr else { die("listen"); }
    let port = ln.port();
    if port <= 0 || port >= 65536 { die("port"); }
    println("reuse listen ok");

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

    let st = c.send_static(b"STAT", until_never());
    guard let sn = st else { die("send_static"); }
    if sn != 4 { die("send_static length"); }
    println("sent static 4");

    let ar = ln.accept(until_never());
    guard let s = ar else { die("accept"); }

    let buf = a.wire(64);
    let rr = s.recv(buf, until_never());
    guard let got = rr else { die("recv"); }
    if got < 4 { die("recv length"); }
    if buf[0] != 80 || buf[1] != 73 || buf[2] != 78 || buf[3] != 71 {
        die("payload");
    }
    let a2 = arena_new(64);
    let spill = a2.wire(64);
    let have = got;
    while have < 12 {
        let tail = spill[have..];
        let rmore = s.recv(tail, until_never());
        guard let gmore = rmore else { die("recv more"); }
        if gmore <= 0 { die("recv more short"); }
        let k = 0;
        while k < gmore {
            if have + k >= 64 { die("overflow"); }
            buf[have + k] = spill[have + k];
            k = k + 1;
        }
        have = have + gmore;
    }
    if buf[4] != 80 || buf[5] != 73 || buf[6] != 78 || buf[7] != 71 {
        die("payload2");
    }
    if buf[8] != 83 || buf[9] != 84 || buf[10] != 65 || buf[11] != 84 {
        die("payload3");
    }
    println("echo payload ok");
    println("echo bytes ok");
    println("echo static ok");

    let p = s.peer();
    if peer_port(p) <= 0 { die("peer"); }
    println("link ok");
}

run();
