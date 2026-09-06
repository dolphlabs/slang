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
    let rr = s.recv(w, until_of(time.mono()));
    guard let n = rr else {
        println("timeout");
        return;
    }
    if n >= 0 { die("expected timeout"); }
}

run();
