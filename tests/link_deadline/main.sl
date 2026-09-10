// A LIVE (future) deadline on link.recv must actually fire.
//
// tests/link_timeout covers only until_of(time.mono()) -- already
// expired, which sl_reactor_wait_until short-circuits before it ever
// parks. That left the reactor's own timer path untested, and it was
// broken: the reactor computed its sleep duration from the waiters it
// could see and only then blocked, so a deadline registered while it
// was already asleep (with no other traffic, asleep forever) was
// never looked at again. This test parks on a real deadline and
// requires it to come back.

import "time";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn run() {
    let lr = link_listen(0);
    guard let ln = lr else { die("listen"); }
    let port = ln.port();
    let dr = link_dial("127.0.0.1", port, until_never());
    guard let c = dr else { die("dial"); }
    let ar = ln.accept(until_never());
    guard let s = ar else { die("accept"); }
    let a = arena_new(32);
    let w = a.wire(16);

    // The peer is connected and completely silent. Nothing else is
    // happening on the reactor, so this deadline is the only thing
    // that can ever wake the task.
    let t0 = time.mono();
    let rr = s.recv(w, until_of(time.mono() + 150000000));
    let waited = time.mono() - t0;
    guard let n = rr else {
        if waited < 100000000 { die("returned too early"); }
        if waited > 5000000000 { die("waited far too long"); }
        println("live deadline fired");
        return;
    }
    if n >= 0 { die("expected timeout"); }
}

run();
