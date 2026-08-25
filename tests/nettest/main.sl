// net: TCP listener/dialer over bytes + fixed ints, exercised fully
// in-process on the loopback interface. listen(0) asks the OS for an
// ephemeral port; net.port() reports which one was assigned.

import "net";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn run() {
    let lr: result[i32, str] = net.listen(0);
    guard let lfd = lr else { die("listen"); }

    let pr: result[i32, str] = net.port(lfd);
    guard let port = pr else { die("port"); }
    if port <= 0 || port >= 65536 { die("ephemeral port range"); }

    let dr: result[i32, str] = net.dial("127.0.0.1", port);
    guard let cfd = dr else { die("dial"); }

    let sr: result[i32, str] = net.send(cfd, b"PING");
    guard let n = sr else { die("send"); }
    if n != 4 { die("send length"); }
    println("sent 4 bytes");

    let ar: result[i32, str] = net.accept(lfd);
    guard let sfd = ar else { die("accept"); }

    let rr: result[bytes, str] = net.recv(sfd, 64);
    guard let data = rr else { die("recv"); }
    if data == b"PING" {
        println("echo payload ok");
    } else {
        die("payload mismatch");
    }

    // second connection: a non-blocking socket with no pending data
    // reports "would block", recovered through the ?? operator
    let dr2: result[i32, str] = net.dial("127.0.0.1", port);
    guard let cfd2 = dr2 else { die("dial2"); }
    let ar2: result[i32, str] = net.accept(lfd);
    guard let sfd2 = ar2 else { die("accept2"); }
    let nbr: result[bool, str] = net.nonblock(sfd2);
    guard let _nb = nbr else { die("nonblock"); }
    let wr: result[bytes, str] = net.recv(sfd2, 16);
    let got: bytes = wr ?? b"WOULD-BLOCK";
    if got == b"WOULD-BLOCK" {
        println("would-block detected");
    } else {
        die("expected would-block");
    }

    net.close(cfd);
    net.close(cfd2);
    net.close(sfd);
    net.close(sfd2);
    net.close(lfd);
    println("net ok");
}

run();
