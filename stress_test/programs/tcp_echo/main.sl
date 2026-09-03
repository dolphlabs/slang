// A real, working raw-TCP echo server -- deliberately NOT HTTP, so it
// stress-tests net.*/the reactor/the worker pool on their own terms
// (small, frequent recv/send round-trips, connection churn) rather
// than through httpkit's parsing layer, which demo/main.sl and its own
// stress harness already exercise thoroughly. Single accept-loop task
// (net.accept() parks -- no polling, no multi-acceptor workaround
// needed, see demo/main.sl's own header comment for why one acceptor
// is correct here, Tier 11 sixth slice) dispatching accepted fds to a
// fixed pool of worker tasks via chan[i32], exactly the same shape
// demo/main.sl's http_accept_loop/http_worker already use.
//
// Protocol: whatever bytes a client sends are echoed back verbatim,
// repeatedly, until the client closes the connection. No framing, no
// length prefix -- a raw byte pipe.

import "net";
import "proc";
import "time";

extern fn atoi(s: str) -> i32;

fn echo_conn(cfd: i32) {
    while true {
        let rr: result[bytes, str] = net.recv(cfd, 65536);
        guard let data = rr else {
            net.close(cfd);
            return;
        }
        if len(data) == 0 {
            net.close(cfd); // peer closed (orderly EOF, not an error)
            return;
        }
        let sr: result[i32, str] = net.send(cfd, data);
        guard let _n = sr else {
            net.close(cfd);
            return;
        }
    }
}

fn tcp_worker(work: chan[i32]) {
    while true {
        let v = chan_recv(work);
        guard let cfd = v else { return; }
        echo_conn(cfd);
    }
}

fn accept_and_queue(lfd: i32, work: chan[i32]) -> bool {
    let ar: result[i32, str] = net.accept(lfd);
    guard let cfd = ar else { return false; }
    chan_send(work, cfd);
    return true;
}

fn accept_loop(lfd: i32, work: chan[i32], done: chan[bool]) {
    while !proc.shutdown_requested() {
        accept_and_queue(lfd, work);
    }
    chan_send(done, true);
}

let port_str: str = proc.getenv("TCP_ECHO_PORT") ?? "9095";
let port = atoi(port_str);
let workers_str: str = proc.getenv("TCP_ECHO_WORKERS") ?? "64";
let workers = atoi(workers_str);

let lr: result[i32, str] = net.listen(port);
guard let lfd = lr else {
    println("could not listen on port " + to_str(port));
    exit(1);
}

let work: chan[i32] = make_chan(workers * 4);
let done: chan[bool] = make_chan(1);

let i = 0;
while i < workers {
    spawn tcp_worker(work);
    i = i + 1;
}
spawn accept_loop(lfd, work, done);

println("tcp echo server listening on port " + to_str(port)
        + " (" + to_str(workers) + " workers)");
println("Ctrl-C (or SIGTERM) for a graceful shutdown.");

while !proc.shutdown_requested() {
    time.sleep(50000000); // 50ms -- the accept loop/workers do the real work
}

println("");
println("shutting down: waiting for acceptor to stop...");
let dv = chan_recv(done);
guard let _dok = dv else {
    println("FAIL: acceptor done-channel closed unexpectedly");
    exit(1);
}
chan_close(work);

println("waiting for in-flight connections to finish...");
while proc.active_tasks() > 0 {
    time.sleep(20000000); // 20ms
}
net.close(lfd);
println("goodbye!");
