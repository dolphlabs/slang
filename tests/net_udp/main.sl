// UDP on the net fd API: bind, send_to/recv_from with the sender's
// address handed back as an opaque value, connected sockets (udp_dial)
// with plain send/recv, deadlines, truncation, and many senders at once.
import "net";
import "time";
import "strings";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn ms(n: int) -> int { return n * 1000000; }

fn soon() -> until { return until_of(time.mono() + ms(5000)); }

fn sender(port: int, id: int, n: int, done: chan[int]) {
    let cr = net.udp_dial("127.0.0.1", port, soon());
    guard let fd = cr else let e = err_of(cr) { println("FAIL dial " + e); chan_send(done, -1); return; }
    for i in 0..n {
        let sr = net.send(fd, to_bytes(to_str(id) + ":" + to_str(i)));
        guard let _n = sr else { chan_send(done, -1); return; }
    }
    net.close(fd);
    chan_send(done, n);
}

fn run() {
    let br = net.udp_bind("127.0.0.1", 0);
    guard let sfd = br else let be = err_of(br) { die("bind: " + be); }
    let pr = net.port(sfd);
    guard let port = pr else { die("port"); }

    // 1. send_to an address resolved once; recv_from names the sender,
    //    and replying to that address reaches it.
    let cr = net.udp_bind("127.0.0.1", 0);
    guard let cfd = cr else { die("client bind"); }
    let ar = net.udp_addr("localhost", port, soon());
    guard let to = ar else let ae = err_of(ar) { die("udp_addr: " + ae); }
    if net.addr_str(to) != "127.0.0.1:" + to_str(port) { die("addr_str " + net.addr_str(to)); }
    let s1 = net.send_to(cfd, b"PING", to);
    guard let n1 = s1 else let se = err_of(s1) { die("send_to: " + se); }
    if n1 != 4 { die("send_to count"); }
    let r1 = net.recv_from_until(sfd, 0, soon());
    guard let got = r1 else let re = err_of(r1) { die("recv_from: " + re); }
    if got[0] != b"PING" { die("payload"); }
    let cp = net.port(cfd) ?? 0;
    if net.addr_str(got[1]) != "127.0.0.1:" + to_str(cp) { die("sender " + net.addr_str(got[1])); }
    let s2 = net.send_to(sfd, b"PONG", got[1]);
    guard let _n2 = s2 else { die("reply"); }
    let r2 = net.recv_from_until(cfd, 64, soon());
    guard let back = r2 else { die("reply recv"); }
    if back[0] != b"PONG" || net.addr_str(back[1]) != net.addr_str(to) { die("reply payload"); }
    println("send_to/recv_from: ok");

    // 2. An empty datagram is a datagram.
    let s3 = net.send_to(cfd, b"", to);
    guard let n3 = s3 else { die("empty send"); }
    let r3 = net.recv_from_until(sfd, 64, soon());
    guard let e3 = r3 else { die("empty recv"); }
    if n3 != 0 || len(e3[0]) != 0 { die("empty datagram"); }
    println("empty datagram: ok");

    // 3. A datagram longer than max is an error, and the next one is
    //    unaffected.
    let _big = net.send_to(cfd, to_bytes(strings.repeat("x", 100)), to);
    let _small = net.send_to(cfd, b"after", to);
    let r4 = net.recv_from_until(sfd, 10, soon());
    if let _t = r4 { die("truncation not reported"); } else let te = err_of(r4) {
        if te != "truncated" { die("truncation gave: " + te); }
    }
    let r5 = net.recv_from_until(sfd, 10, soon());
    guard let a5 = r5 else { die("after truncation"); }
    if a5[0] != b"after" { die("after truncation payload"); }
    println("truncated: reported");

    // 4. A silent socket times out after waiting, not before.
    let t0 = time.mono();
    let r6 = net.recv_from_until(sfd, 64, until_of(time.mono() + ms(150)));
    let waited = time.mono() - t0;
    if let _d6 = r6 { die("silent socket returned data"); } else let e6 = err_of(r6) {
        if e6 != "timeout" { die("silent socket gave: " + e6); }
        if waited < ms(100) { die("returned too early"); }
    }
    println("silent socket: timeout after waiting");

    // 5. Connected sockets from many tasks at once; the server parks
    //    between datagrams and counts every one.
    let tasks = 4;
    let each = 50;
    let done: chan[int] = make_chan(tasks);
    for t in 0..tasks {
        spawn sender(port, t, each, done);
    }
    let seen = 0;
    let bytes_seen = 0;
    while seen < tasks * each {
        let rr = net.recv_from_until(sfd, 64, soon());
        guard let d = rr else let ee = err_of(rr) { die("many recv after " + to_str(seen) + ": " + ee); }
        seen = seen + 1;
        bytes_seen = bytes_seen + len(d[0]);
    }
    let sent = 0;
    for t in 0..tasks {
        sent = sent + (chan_recv(done) ?? -1);
    }
    if sent != tasks * each { die("senders reported " + to_str(sent)); }
    println("many senders: " + to_str(seen) + " datagrams");

    // 6. Errors: a bad address, a bad bind host, a bad group, and a
    //    closed socket.
    let bad = net.send_to(cfd, b"x", b"nope");
    if let _b = bad { die("bad address accepted"); }
    let bh = net.udp_bind("not an ip", 0);
    if let _h = bh { die("bad bind host accepted"); }
    let bg = net.udp_join(sfd, "nope", "");
    if let _g = bg { die("bad group accepted"); } else let ge = err_of(bg) { println("bad group: " + ge); }
    let v6 = net.udp_addr("::1", 53, soon());
    guard let a6 = v6 else { die("ipv6 literal"); }
    println("ipv6 literal: " + net.addr_str(a6));
    net.close(cfd);
    net.close(sfd);
    println("done");
}

run();
