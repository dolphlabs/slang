// 200 connections ping-pong 100 messages each, every receive with a
// deadline: what the reactor does per wait, under many waiters.
// tests/run_tests.sh reads SLANG_REACTOR_STAT and checks:
// - about one registration (epoll_ctl / kevent) per wait: each used to
//   be ADD, failing with EEXIST, then MOD;
// - few passes over all waiters: one used to run before and after every
//   batch of events, now only when a deadline may be due.
// This checks every message arrives intact.

fn soon() -> until {
    return until_of(time.mono() + 10000000000);
}

fn echo(c: link, n: int, done: chan[int]) {
    let a = arena_new(256);
    let w = a.wire(64);
    let i = 0;
    while i < n {
        let rr = c.recv(w, soon());
        guard let got = rr else { chan_send(done, -1); return; }
        let sr = c.send(w[0..got], soon());
        guard let _s = sr else { chan_send(done, -1); return; }
        i = i + 1;
    }
    chan_send(done, 1);
}

fn ping(c: link, id: int, n: int, done: chan[int]) {
    let a = arena_new(256);
    let w = a.wire(64);
    let i = 0;
    while i < n {
        let msg = to_bytes("m" + to_str(id) + "." + to_str(i));
        let sr = c.send_bytes(msg, soon());
        guard let _s = sr else { chan_send(done, -1); return; }
        let rr = c.recv(w, soon());
        guard let got = rr else { chan_send(done, -1); return; }
        if to_bytes(w[0..got]) != msg { chan_send(done, -2); return; }
        i = i + 1;
    }
    chan_send(done, 1);
}

import "time";

let pairs = 200;
let rounds = 100;
let lr = link_listen(0);
guard let ln = lr else { println("FAIL listen"); exit(1); }
let done: chan[int] = make_chan(2 * pairs);
let i = 0;
while i < pairs {
    let dr = link_dial("127.0.0.1", ln.port(), soon());
    guard let c = dr else { println("FAIL dial"); exit(1); }
    let ar = ln.accept(soon());
    guard let s = ar else { println("FAIL accept"); exit(1); }
    spawn echo(s, rounds, done);
    spawn ping(c, i, rounds, done);
    i = i + 1;
}
let ok = 0;
i = 0;
while i < 2 * pairs {
    if (chan_recv(done) ?? 0) == 1 { ok = ok + 1; }
    i = i + 1;
}
println("ok " + to_str(ok) + " of " + to_str(2 * pairs));
