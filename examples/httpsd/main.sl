// HTTPS variant of examples/httpd: identical shape, but net.accept /
// net.recv / net.send / net.close become their net.tls_* equivalents.
// The TLS server context (loaded from cert.pem/key.pem once) is
// reused across every connection; each connection still gets its own
// spawned thread so one slow client can't stall the others. SIGTERM/
// SIGINT stop the accept loop and wait for in-flight connections to
// finish instead of dropping them -- see the 'proc' package.

import "net";
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

fn serve(conn: rawptr) {
    // drain the request head; a minimal server needs no parsing
    net.tls_recv(conn, 8192);
    let body = "<html><body><h1>Hello from slang, over TLS</h1>"
        + "<p>served by the slang net package's tls_* functions</p>"
        + "</body></html>";
    net.tls_send(conn, page(body));
    net.tls_close(conn);
}

// the language has no 'continue' statement, so a failed accept just
// returns from this helper instead of skipping ahead in the loop body
fn accept_and_serve(lfd: i32, sctx: rawptr) {
    let ar: result[rawptr, str] = net.tls_accept(lfd, sctx);
    guard let conn = ar else { return; }
    spawn serve(conn);
}

let sctx_r: result[rawptr, str] =
    net.tls_server_ctx("examples/httpsd/cert.pem", "examples/httpsd/key.pem");
guard let sctx = sctx_r else {
    println("could not load cert/key");
    exit(1);
}

let lr: result[i32, str] = net.listen(8443);
guard let lfd = lr else {
    println("could not listen on 8443");
    exit(1);
}
println("listening on https://localhost:8443");
println("(self-signed cert -- e.g. curl -k https://localhost:8443/)");

while !proc.shutdown_requested() {
    accept_and_serve(lfd, sctx);
}

println("shutting down: waiting for in-flight connections to finish");
while proc.active_tasks() > 0 {
    time.sleep(20000000); // 20ms
}
net.close(lfd);
println("done");
