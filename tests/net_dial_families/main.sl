// net.dial and link_dial resolve IPv4 and IPv6 and race the addresses
// (happy eyeballs, RFC 8305). An IPv6 literal is dialed rather than
// refused by the resolver, and a name with addresses in both families
// reaches whichever one is listening.
import "net";
import "time";
import "strings";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn soon() -> until { return until_of(time.mono() + 5000000000); }

fn accept_n(lfd: i32, n: int) {
    for _ in 0..n {
        let ar = net.accept(lfd);
        guard let fd = ar else { return; }
        let _s = net.send(fd, b"hello");
        net.close(fd);
    }
}

fn run() {
    let lr = net.listen(0);
    guard let lfd = lr else { die("listen"); }
    let port = net.port(lfd) ?? 0;
    spawn accept_n(lfd, 3);

    // 1. An IPv6 literal is dialed: nothing listens on ::1 at this port,
    //    so the answer is a refused connection, not "unknown host".
    let r6 = net.dial_until("::1", port, soon());
    if let fd6 = r6 { net.close(fd6); die("::1 connected to an IPv4-only listener"); } else let e6 = err_of(r6) {
        if strings.contains(e6, "nodename") || strings.contains(e6, "not known") || strings.contains(e6, "Name or service") {
            die("::1 went to the resolver: " + e6);
        }
        println("::1: dialed, refused");
    }

    // 2. "localhost" names ::1 and 127.0.0.1: the IPv4 listener is
    //    reached whichever family is tried first.
    let rl = net.dial_until("localhost", port, soon());
    guard let fl = rl else let el = err_of(rl) { die("localhost: " + el); }
    if (net.recv_until(fl, 16, soon()) ?? b"") != b"hello" { die("localhost data"); }
    net.close(fl);
    println("localhost: connected");

    // 3. The same through link_dial.
    let lk = link_dial("localhost", port, soon());
    guard let _l = lk else { die("link_dial localhost"); }
    println("link_dial localhost: connected");

    // 4. An IPv4 literal is unchanged.
    let r4 = net.dial_until("127.0.0.1", port, soon());
    guard let f4 = r4 else { die("127.0.0.1"); }
    if (net.recv_until(f4, 16, soon()) ?? b"") != b"hello" { die("ipv4 data"); }
    net.close(f4);
    println("127.0.0.1: connected");

    // 5. A deadline already passed is still a timeout.
    let rt = net.dial_until("localhost", port, until_of(time.mono()));
    if let ft = rt { net.close(ft); die("expired deadline connected"); } else let et = err_of(rt) {
        println("expired deadline: " + et);
    }
    net.close(lfd);
    println("done");
}

run();
