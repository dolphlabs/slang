import "proc";

extern fn atoi(s: str) -> i32;

fn fill_wire(dst: wire, src: bytes) {
    let i = 0;
    for b in src {
        dst[i] = b;
        i = i + 1;
    }
}

fn serve(c: link) {
    let a = arena_new(4096);
    let buf = a.wire(2048);
    let rr = c.recv(buf, until_never());
    guard let n = rr else { return; }
    if n == 0 { return; }
    let resp = b"HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 200\r\nConnection: close\r\n\r\n0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef01234567";
    let out = a.wire(len(resp));
    fill_wire(out, resp);
    let sr = c.send(out, until_never());
    guard let _s = sr else { return; }
}

let port_str: str = proc.getenv("HTTP_PORT") ?? "0";
let port = atoi(port_str);
let lr = link_listen(port);
guard let ln = lr else {
    println("listen failed");
    exit(1);
}
println("LISTEN_PORT " + to_str(ln.port()));
while true {
    let ar = ln.accept(until_never());
    guard let c = ar else { continue; }
    spawn serve(c);
}
