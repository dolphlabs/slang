// Minimal HTTP server: link + arena so the request buffer never
// touches the GC heap. Each connection is a spawned task. SIGTERM/
// SIGINT stop accept and wait for in-flight work -- see 'proc'.

import "proc";
import "time";

fn page(body: str) -> bytes {
    let head = "HTTP/1.0 200 OK\r\n"
        + "Content-Type: text/html; charset=utf-8\r\n"
        + "Content-Length: " + to_str(len(body)) + "\r\n"
        + "Connection: close\r\n"
        + "\r\n";
    return to_bytes(head + body);
}

fn send_page(c: link, a: &mut arena, body: str) {
    let raw = page(body);
    let w = a.wire(len(raw));
    let i = 0;
    while i < len(raw) {
        w[i] = raw[i];
        i = i + 1;
    }
    let sr = c.send(w, until_never());
    guard let _n = sr else { return; }
}

fn serve(c: link) {
    let a = arena_new(16384);
    let buf = a.wire(8192);
    let rr = c.recv(buf, until_never());
    guard let _n = rr else { return; }
    let body = "<html><body><h1>Hello from slang</h1>"
        + "<p>served by the slang net package</p></body></html>";
    send_page(c, &mut a, body);
}

fn accept_and_serve(ln: &mut link) {
    let ar = ln.accept(until_never());
    guard let c = ar else { return; }
    spawn serve(c);
}

let lr = link_listen(8080);
guard let ln = lr else {
    println("could not listen on 8080");
    exit(1);
}
println("listening on http://localhost:8080");

while !proc.shutdown_requested() {
    accept_and_serve(&mut ln);
}

println("shutting down: waiting for in-flight connections to finish");
while proc.active_tasks() > 0 {
    time.sleep(20000000);
}
println("done");
