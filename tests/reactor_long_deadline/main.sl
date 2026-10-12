// A deadline further off than the reactor's longest sleep
// (SL_REACTOR_MAX_SLEEP_NS, 1 s) must still fire, on time.
//
// Such a waiter never nudges the reactor: it finds it already due to
// wake within the cap and relies on that wake's scan to see its deadline
// and sleep until it. Nothing else happens on the reactor here, so if
// the scan missed it the recv would wait forever.

import "time";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

let lr = link_listen(0);
guard let ln = lr else { die("listen"); }
let port = ln.port();
let dr = link_dial("127.0.0.1", port, until_never());
guard let c = dr else { die("dial"); }
let ar = ln.accept(until_never());
guard let s = ar else { die("accept"); }
let a = arena_new(32);
let w = a.wire(16);

let budget = 1300000000;
let t0 = time.mono();
let rr = s.recv(w, until_of(time.mono() + budget));
let waited = time.mono() - t0;
guard let _n = rr else {
    if waited < budget - 50000000 { die("fired early: " + to_str(waited)); }
    if waited > budget + 1000000000 { die("fired late: " + to_str(waited)); }
    println("long deadline fired on time");
    exit(0);
}
die("recv returned data from a silent peer");
