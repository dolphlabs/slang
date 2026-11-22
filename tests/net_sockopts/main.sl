// net.listen_with (bind address, reuseport, v6only, backlog, fastopen)
// and net.set_opt / net.get_opt by name.
import "net";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn want_opt(fd: int, name: str, value: int) {
    let sr = net.set_opt(fd, name, value);
    guard let _ok = sr else let e = err_of(sr) { die("set " + name + ": " + e); }
    let gr = net.get_opt(fd, name);
    guard let got = gr else let e2 = err_of(gr) { die("get " + name + ": " + e2); }
    if got != value { die(name + " read back " + to_str(got) + ", want " + to_str(value)); }
}

fn run() {
    // 1. A listener on one address with a backlog; options on the
    //    accepted connection read back as set.
    let lr = net.listen_with("127.0.0.1", 0, "backlog=16, fastopen=8");
    guard let lfd = lr else let le = err_of(lr) { die("listen_with: " + le); }
    let port = net.port(lfd) ?? 0;
    let dr = net.dial("127.0.0.1", port);
    guard let cfd = dr else { die("dial"); }
    let ar = net.accept(lfd);
    guard let sfd = ar else { die("accept"); }
    want_opt(sfd, "nodelay", 1);
    want_opt(sfd, "nodelay", 0);
    want_opt(sfd, "keepalive", 1);
    want_opt(sfd, "keepidle", 30);
    want_opt(sfd, "keepintvl", 5);
    want_opt(sfd, "keepcnt", 4);
    want_opt(sfd, "ttl", 32);
    let lg = net.get_opt(sfd, "linger") ?? -9;
    if lg != -1 { die("linger default " + to_str(lg)); }
    want_opt(sfd, "linger", 3);
    want_opt(sfd, "linger", -1);
    let rb = net.set_opt(sfd, "rcvbuf", 65536);
    guard let _rb = rb else { die("rcvbuf"); }
    if (net.get_opt(sfd, "rcvbuf") ?? 0) < 65536 { die("rcvbuf read back small"); }
    // quickack is Linux-only: either it works or it says so
    let qa = net.set_opt(sfd, "quickack", 1);
    if let _q = qa { } else let qe = err_of(qa) {
        if qe != "option not supported on this system" { die("quickack: " + qe); }
    }
    let sr = net.send(cfd, b"hi");
    guard let _s = sr else { die("send"); }
    if (net.recv(sfd, 8) ?? b"") != b"hi" { die("data through tuned socket"); }
    println("options: read back");

    // 2. reuseport: a second listener on the same port succeeds with it
    //    and fails without it.
    let r1 = net.listen_with("127.0.0.1", 0, "reuseport");
    guard let a1 = r1 else let e1 = err_of(r1) { die("reuseport 1: " + e1); }
    let rp = net.port(a1) ?? 0;
    let r2 = net.listen_with("127.0.0.1", rp, "reuseport");
    guard let a2 = r2 else let e2 = err_of(r2) { die("reuseport 2: " + e2); }
    let r3 = net.listen_with("127.0.0.1", rp, "");
    if let _a3 = r3 { die("plain listener shared a reuseport port"); }
    println("reuseport: shared, plain refused");

    // 3. An IPv6 listener (net.dial is IPv4-only until the DNS resolver
    //    item, so this checks the bind and the port, not a connection).
    let r6 = net.listen_with("::1", 0, "v6only");
    guard let l6 = r6 else let e6 = err_of(r6) { die("ipv6 listen: " + e6); }
    if (net.port(l6) ?? 0) <= 0 { die("ipv6 port"); }
    let any6 = net.listen_with("::", 0, "");
    guard let l6b = any6 else let e6b = err_of(any6) { die("ipv6 any: " + e6b); }
    println("ipv6 listener: bound");

    // 4. Errors say what is wrong.
    let bad1 = net.listen_with("", 0, "reuseprot");
    if let _b1 = bad1 { die("typo accepted"); } else let be1 = err_of(bad1) { println(be1); }
    let bad2 = net.listen_with("", 0, "backlog=lots");
    if let _b2 = bad2 { die("bad number accepted"); } else let be2 = err_of(bad2) { println(be2); }
    let bad3 = net.listen_with("example.com", 0, "");
    if let _b3 = bad3 { die("hostname accepted"); } else let be3 = err_of(bad3) { println(be3); }
    let bad4 = net.listen_with("127.0.0.1", 0, "v6only");
    if let _b4 = bad4 { die("v6only on IPv4 accepted"); } else let be4 = err_of(bad4) { println(be4); }
    let bad5 = net.set_opt(sfd, "nodely", 1);
    if let _b5 = bad5 { die("unknown option accepted"); } else let be5 = err_of(bad5) { println(be5); }
    for fd in [cfd, sfd, lfd, a1, a2, l6, l6b] {
        net.close(fd);
    }
    println("done");
}

run();
