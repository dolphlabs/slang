// Minimal HTTP server in slang: the net package's TCP listener and
// dialer are built on bytes + fixed-width ints, every fallible
// operation returns a Result unwrapped with guard let, and each
// connection is served on its own spawned thread so one slow client
// can't stall the others. SIGTERM/SIGINT (e.g. Ctrl-C, or `kill`)
// stop the accept loop and wait for in-flight connections to finish
// instead of dropping them -- see the 'proc' package.

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

fn serve(cfd: i32) {
    // drain the request head; a minimal server needs no parsing
    net.recv(cfd, 8192);
    let body = "<html><body><h1>Hello from slang</h1>"
        + "<p>served by the slang net package</p></body></html>";
    net.send(cfd, page(body));
    net.close(cfd);
}

// the language has no 'continue' statement, so a failed accept just
// returns from this helper instead of skipping ahead in the loop body
fn accept_and_serve(lfd: i32) {
    let ar: result[i32, str] = net.accept(lfd);
    guard let cfd = ar else { return; }
    spawn serve(cfd);
}

let lr: result[i32, str] = net.listen(8080);
guard let lfd = lr else {
    println("could not listen on 8080");
    exit(1);
}
println("listening on http://localhost:8080");

while !proc.shutdown_requested() {
    accept_and_serve(lfd);
}

println("shutting down: waiting for in-flight connections to finish");
while proc.active_tasks() > 0 {
    time.sleep(20000000); // 20ms
}
net.close(lfd);
println("done");
