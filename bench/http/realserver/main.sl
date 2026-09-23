// Real-server axis: actual HTTP/1.1 parsing and serialization through
// stdlib/http, keep-alive, same shape as examples/httpd but with the
// port/acceptor knobs bench/http_opt/main.sl uses so it can be raced
// the same way. Unlike bench/http/main.sl (the frozen raw-bytes ruler,
// one recv, Connection: close), this is the axis that answers "what
// does parsing a real request actually cost" -- see bench/http/README.md.
import "http";
import "proc";

extern fn atoi(s: str) -> i32;

fn serve(c: link) {
    let body = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef01234567";
    let ra = arena_new(8192);
    let sa = arena_new(2048);
    let buf = ra.wire(4096);
    let filled = 0;
    while true {
        let rr = http.read(&mut c, buf, filled, until_never());
        guard let got = rr else { return; }
        let wr = http.write(&mut c, http.ok_text(body), &mut sa, until_never());
        guard let _n = wr else { return; }
        sa.reset();
        if http.wants_close(got.req) {
            return;
        }
        filled = got.filled;
    }
}

fn accept_loop(ln: link) {
    while true {
        let ar = ln.accept(until_never());
        guard let c = ar else { continue; }
        spawn serve(c);
    }
}

let port_str: str = proc.getenv("HTTP_PORT") ?? "0";
let port = atoi(port_str);
let n_str: str = proc.getenv("HTTP_ACCEPTORS") ?? "1";
let n = atoi(n_str);
if n < 1 { n = 1; }

let i = 0;
while i < n {
    let lr = link_listen(port, 1);
    guard let ln = lr else {
        println("listen failed");
        exit(1);
    }
    if i == 0 {
        println("LISTEN_PORT " + to_str(ln.port()));
    }
    if i == n - 1 {
        accept_loop(ln);
    } else {
        spawn accept_loop(ln);
    }
    i = i + 1;
}
