// On Linux a connected socket is registered with epoll once, at its first
// wait, and stays registered until it is closed; every close must drop
// that registration, or the number's next owner looks registered and its
// first wait parks for an edge nobody asked for. Each round here opens a
// connection, parks on it in both directions, and closes it through one of
// the three ways a program can -- net.close, fs.close, a link going out of
// scope -- so the next round's sockets reuse the numbers just freed.
import "net";
import "fs";
import "time";

fn ms(n: int) -> int { return n * 1000000; }

fn watchdog(n: int) {
    time.sleep(ms(n));
    println("FAIL a wait on a reused fd number never woke");
    exit(1);
}

fn soon() -> until {
    return until_of(time.mono() + ms(3000));
}

fn conn(lfd: i32, port: int) -> [int] {
    let dr = net.dial("127.0.0.1", port);
    guard let c = dr else let e = err_of(dr) { println("dial: " + e); exit(1); }
    let ar = net.accept(lfd);
    guard let s = ar else let e = err_of(ar) { println("accept: " + e); exit(1); }
    return [c as int, s as int];
}

// Parks on fd for read (nothing has been sent yet) and reports what came.
fn reader(fd: int, out: chan[str]) {
    let r = net.recv_until(fd as i32, 64, soon());
    if let b = r {
        chan_send(out, to_str(b));
    } else let e = err_of(r) {
        chan_send(out, "recv: " + e);
    }
}

// Fills fd's send buffer until the send parks for write, then reports how
// it ended once the peer drains it.
fn flooder(fd: int, total: int, out: chan[str]) {
    let block = b"0123456789abcdef0123456789abcdef";
    for i in 0..11 {
        block = block + block;
    }
    let sent = 0;
    while sent < total {
        let r = net.send_until(fd as i32, block, soon());
        guard let n = r else let e = err_of(r) {
            chan_send(out, "send: " + e);
            return;
        }
        sent = sent + (n as int);
    }
    chan_send(out, "sent");
}

fn drain(fd: int, total: int) -> bool {
    let got = 0;
    while got < total {
        let r = net.recv_until(fd as i32, 65536, soon());
        guard let b = r else { return false; }
        if len(b) == 0 { return false; }
        got = got + len(b);
    }
    return true;
}

// One round on a raw-fd pair: a read park, then a write park.
fn round_fds(lfd: i32, port: int) -> [int] {
    let p = conn(lfd, port);
    let rd: chan[str] = make_chan(1);
    spawn reader(p[1], rd);
    time.sleep(ms(5));
    net.send(p[0] as i32, b"ping");
    let got = chan_recv(rd) ?? "channel closed";
    if got != "ping" { println("FAIL read park: " + got); exit(1); }

    let total = 4 * 1024 * 1024;
    let wr: chan[str] = make_chan(1);
    spawn flooder(p[0], total, wr);
    time.sleep(ms(5));
    if !drain(p[1], total) { println("FAIL drain"); exit(1); }
    let how = chan_recv(wr) ?? "channel closed";
    if how != "sent" { println("FAIL write park: " + how); exit(1); }
    return p;
}

// One round on links: both ends go out of scope when this returns.
fn round_link(ln: &mut link, port: int) {
    let dr = link_dial("127.0.0.1", port, soon());
    guard let c = dr else { println("FAIL link dial"); exit(1); }
    let ar = ln.accept(soon());
    guard let s = ar else { println("FAIL link accept"); exit(1); }
    let a = arena_new(256);
    let w = a.wire(64);
    time.sleep(ms(2));
    c.send_bytes(b"pong", soon());
    let sr = s.recv(w, soon());
    guard let n = sr else { println("FAIL link recv"); exit(1); }
    if to_bytes(w[0..n]) != b"pong" { println("FAIL link data"); exit(1); }
}

spawn watchdog(20000);
let lr = net.listen(0);
guard let lfd = lr else let e = err_of(lr) { println("listen: " + e); exit(1); }
let pr = net.port(lfd);
guard let port = pr else { println("port"); exit(1); }
let llr = link_listen(0);
guard let ln = llr else { println("FAIL link listen"); exit(1); }
let lport = ln.port();

let rounds = 30;
let i = 0;
while i < rounds {
    let p = round_fds(lfd, port);
    if i % 2 == 0 {
        net.close(p[0] as i32);
        net.close(p[1] as i32);
    } else {
        fs.close(p[0]);
        fs.close(p[1]);
    }
    round_link(&mut ln, lport);
    i = i + 1;
}
println("ok " + to_str(rounds) + " rounds");
