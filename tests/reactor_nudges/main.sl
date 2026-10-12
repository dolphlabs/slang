// Keep-alive traffic where every recv carries a deadline, the shape of
// an HTTP server with idle and read timeouts. Each wait that parks must
// let the reactor see its deadline, but only a wait the reactor would
// otherwise sleep past needs to nudge it (a write(2) and an extra
// reactor wakeup). tests/run_tests.sh runs this under SLANG_SCHED_STAT
// and checks reactor_nudges against deadline_waits: before the
// registration-count protocol and the 1 s sleep cap (runtime/sl_net.c,
// sl_reactor_wake_at), about half of all such waits nudged, because
// "computing" and "nudge me" were the same value.

import "time";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn dl() -> until {
    return until_of(time.mono() + 10000000000);
}

fn echo(s: link, rounds: int, done: chan[int]) {
    let a = arena_new(64);
    let w = a.wire(8);
    let i = 0;
    while i < rounds {
        let rr = s.recv(w, dl());
        guard let n = rr else { chan_send(done, -1); return; }
        if n != 1 { chan_send(done, -1); return; }
        let sr = s.send(w[0..1], dl());
        guard let _m = sr else { chan_send(done, -1); return; }
        i = i + 1;
    }
    chan_send(done, 1);
}

fn client(port: int, rounds: int, done: chan[int]) {
    let dr = link_dial("127.0.0.1", port, dl());
    guard let c = dr else { chan_send(done, -1); return; }
    let a = arena_new(64);
    let w = a.wire(8);
    w[0] = 120;
    let i = 0;
    while i < rounds {
        let sr = c.send(w[0..1], dl());
        guard let _m = sr else { chan_send(done, -1); return; }
        let rr = c.recv(w, dl());
        guard let n = rr else { chan_send(done, -1); return; }
        if n != 1 { chan_send(done, -1); return; }
        i = i + 1;
    }
    chan_send(done, 1);
}

let conns = 32;
let rounds = 400;
let lr = link_listen(0);
guard let ln = lr else { die("listen"); }
let port = ln.port();
let done: chan[int] = make_chan(conns * 2);
let k = 0;
while k < conns {
    spawn client(port, rounds, done);
    let ar = ln.accept(dl());
    guard let s = ar else { die("accept"); }
    spawn echo(s, rounds, done);
    k = k + 1;
}
let ok_n = 0;
let j = 0;
while j < conns * 2 {
    let vr = chan_recv(done);
    guard let v = vr else { die("channel closed"); }
    if v == 1 {
        ok_n = ok_n + 1;
    }
    j = j + 1;
}
if ok_n != conns * 2 {
    die(to_str(conns * 2 - ok_n) + " tasks failed");
}
println("round trips: " + to_str(conns * rounds));
