import "strings";
// to_str(peer) renders an address the way println and inspect already do
// ("1.2.3.4:5678"); it used to be an internal compiler error ("no str
// conversion for peer", at line 0).

fn run() {
    let p = peer_v4(10, 0, 0, 4, 8080);
    println(to_str(p));
    if to_str(p) != inspect(p) {
        println("FAIL to_str and inspect disagree");
        exit(1);
    }
    println("edge " + to_str(peer_v4(255, 255, 255, 255, 65535)));
    println("zero " + to_str(peer_v4(0, 0, 0, 0, 0)));

    // a connection's real peer
    let lr = link_listen(0);
    guard let ln = lr else { println("FAIL listen"); exit(1); }
    let dr = link_dial("127.0.0.1", ln.port(), until_never());
    guard let c = dr else { println("FAIL dial"); exit(1); }
    let ar = ln.accept(until_never());
    guard let s = ar else { println("FAIL accept"); exit(1); }
    let text = to_str(s.peer());
    if !strings.has_prefix(text, "127.0.0.1:") || len(text) <= 10 {
        println("FAIL peer " + text);
        exit(1);
    }
    println("link peer ok");
}

run();
