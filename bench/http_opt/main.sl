import "proc";

extern fn atoi(s: str) -> i32;

fn serve(c: link) {
    let a = arena_new(4096);
    let buf = a.wire(2048);
    let rr = c.recv(buf, until_never());
    guard let n = rr else { return; }
    if n == 0 { return; }
    let sr = c.send_static(b"HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 200\r\nConnection: close\r\n\r\n0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef01234567", until_never());
    guard let _s = sr else { return; }
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
