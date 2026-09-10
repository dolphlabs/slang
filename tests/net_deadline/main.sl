// net.recv_until / net.send_until: deadline-bounded I/O on the fd API.
//
// Without these, a peer that connects and then neither sends nor reads
// parks the serving task on the reactor forever -- it holds its stack
// and its GC roots, and nothing ever wakes it. That is slowloris. The
// deadline variants return the reserved error string "timeout" so the
// caller can tell a dead peer from a broken one.

import "net";
import "time";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn ms(n: int) -> int { return n * 1000000; }

fn run() {
    let lr = net.listen(0);
    guard let lfd = lr else { die("listen"); }
    let pr = net.port(lfd);
    guard let port = pr else { die("port"); }

    let dr = net.dial("127.0.0.1", port);
    guard let cfd = dr else { die("dial"); }
    let ar = net.accept(lfd);
    guard let sfd = ar else { die("accept"); }

    // 1. A deadline already in the past never touches the socket.
    let r1 = net.recv_until(sfd, 64, until_of(time.mono()));
    guard let _d1 = r1 else let e1 = err_of(r1) {
        if e1 != "timeout" { die("expired deadline gave: " + e1); }
        println("expired deadline: timeout");
    }

    // 2. A live deadline against a silent peer waits, then times out.
    //    The elapsed check is what proves it parked rather than
    //    spinning or returning early.
    let t0 = time.mono();
    let r2 = net.recv_until(sfd, 64, until_of(time.mono() + ms(150)));
    let waited = time.mono() - t0;
    guard let _d2 = r2 else let e2 = err_of(r2) {
        if e2 != "timeout" { die("silent peer gave: " + e2); }
        if waited < ms(100) { die("returned too early"); }
        if waited > ms(3000) { die("waited far too long"); }
        println("silent peer: timeout after waiting");
    }

    // 3. Data that arrives before the deadline comes back normally --
    //    the deadline must not disturb the success path.
    let sr = net.send(cfd, b"PING");
    guard let _n = sr else { die("send"); }
    let r3 = net.recv_until(sfd, 64, until_of(time.mono() + ms(5000)));
    guard let d3 = r3 else let e3 = err_of(r3) { die("recv_until: " + e3); }
    if d3 != b"PING" { die("payload mismatch"); }
    println("live deadline: payload ok");

    // 4. send_until on a writable socket behaves exactly like send.
    let r4 = net.send_until(sfd, b"PONG", until_of(time.mono() + ms(5000)));
    guard let n4 = r4 else let e4 = err_of(r4) { die("send_until: " + e4); }
    if n4 != 4 { die("send_until length"); }
    let r5 = net.recv(cfd, 64);
    guard let d5 = r5 else { die("recv back"); }
    if d5 != b"PONG" { die("send_until payload"); }
    println("send_until: ok");

    // 5. An expired deadline refuses to write a non-empty buffer.
    let r6 = net.send_until(sfd, b"NOPE", until_of(time.mono()));
    guard let _n6 = r6 else let e6 = err_of(r6) {
        if e6 != "timeout" { die("expired send gave: " + e6); }
        println("expired send: timeout");
    }

    net.close(cfd);
    net.close(sfd);
    net.close(lfd);
    println("net deadline ok");
}

run();
