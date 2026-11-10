// nats reconnection against a scripted server in the same program: the
// first connection is dropped after one message; the client must dial
// again, send CONNECT, replay its SUB before anything else, then the
// publish it buffered while disconnected. Also: a protocol violation
// (an unknown line) drops the connection the same way.

import "nats";
import "net";
import "strings";
import "time";


fn soon() -> until {
    return until_of(time.mono() + 5000000000);
}

fn recv_until_has(fd: int, buf: str, want: str) -> str {
    let have = buf;
    while !strings.contains(have, want) {
        let r = net.recv_until(fd, 4096, soon());
        guard let b = r else let e = err_of(r) { panic("server recv: " + e); }
        if len(b) == 0 {
            panic("server: client closed while waiting for " + want);
        }
        have = have + to_str(b);
    }
    return have;
}

fn send(fd: int, s: str) {
    net.send_until(fd, to_bytes(s), soon());
}

fn info() -> str {
    return "INFO {\"server_id\":\"fake\",\"max_payload\":1048576,\"headers\":true}\r\n";
}

fn server(lfd: int, done: chan[str]) {
    // ---- first connection: deliver one message, then drop it ----
    let a = net.accept(lfd) ?? -1;
    send(a, info());
    let got = recv_until_has(a, "", "PING\r\n");
    if !strings.has_prefix(got, "CONNECT {") {
        chan_send(done, "first line was not CONNECT: " + got);
        return;
    }
    send(a, "PONG\r\n");
    got = recv_until_has(a, "", "SUB rc.x 1\r\n");
    send(a, "MSG rc.x 1 5\r\nhello\r\n");
    time.sleep(100000000);
    net.close(a);
    // ---- second connection: expect CONNECT, then SUB before the PUB ----
    time.sleep(300000000);
    let b = net.accept(lfd) ?? -1;
    send(b, info());
    got = recv_until_has(b, "", "PING\r\n");
    send(b, "PONG\r\n");
    got = recv_until_has(b, "", "queued\r\n");
    let si = strings.find(got, "SUB rc.x 1\r\n");
    let pi = strings.find(got, "PUB rc.x 6\r\nqueued\r\n");
    if si < 0 || pi < 0 || si > pi {
        chan_send(done, "after reconnect, expected SUB then PUB, got: " + got);
        return;
    }
    send(b, "MSG rc.x 1 6\r\nqueued\r\n");
    // ---- then a protocol violation: the client must drop and redial ----
    time.sleep(100000000);
    send(b, "BOGUS line\r\n");
    let c = net.accept(lfd) ?? -1;
    send(c, info());
    got = recv_until_has(c, "", "PING\r\n");
    send(c, "PONG\r\n");
    got = recv_until_has(c, "", "SUB rc.x 1\r\n");
    send(c, "MSG rc.x 1 5\r\nagain\r\n");
    chan_send(done, "ok");
    time.sleep(500000000);
    net.close(b);
    net.close(c);
}

let PORT = 54911;
let lr = net.listen(PORT);
guard let lfd = lr else let e = err_of(lr) { panic(e); }
let done: chan[str] = make_chan(1);
spawn server(lfd as int, done);

let o = nats.options("nats://127.0.0.1:" + to_str(PORT));
o.reconnect_wait = 40000000;
let cr = nats.connect_with(o, soon());
guard let nc = cr else let e = err_of(cr) { panic(e); }
let sr = nats.subscribe(nc, "rc.x");
guard let s = sr else let e = err_of(sr) { panic(e); }
nats.flush(nc, soon());
let m1 = nats.next_msg(s, soon()) ?? none;
println(to_str((m1 ?? panic_msg()).data));
// wait for the drop, then publish while disconnected: it must be kept
let waited = 0;
while nats.is_connected(nc) && waited < 2000 {
    time.sleep(5000000);
    waited += 5;
}
println(!nats.is_connected(nc));
nats.publish(nc, "rc.x", b"queued");
let m2 = nats.next_msg(s, soon()) ?? none;
println(to_str((m2 ?? panic_msg()).data));
let m3 = nats.next_msg(s, soon()) ?? none;
println(to_str((m3 ?? panic_msg()).data));
println(nats.reconnects(nc));
println(chan_recv(done) ?? "server gave up");
nats.close(nc);
println(nats.is_connected(nc));

fn panic_msg() -> nats.Msg {
    panic("no message");
}
