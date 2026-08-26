// Graceful shutdown, exercised end to end: a real listener, a real
// SIGTERM (sent to this process via extern-fn'd libc kill()/getpid(),
// not raise() -- raise() targets only the calling thread, which
// wouldn't exercise the process-wide delivery path a real `kill -TERM
// <pid>` uses), and a real in-flight connection that must be allowed
// to finish rather than get dropped.
//
// The mechanism (see stmt.c's ST_SPAWN codegen and pkg_proc/runtime.c):
// every 'spawn'ed thread has SIGTERM/SIGINT blocked in its own mask
// from birth, so the OS can only ever pick the main thread to run the
// handler -- which is what lets a blocked net.accept() on the main
// thread reliably observe the interruption (EINTR, surfaced as a
// result error, no SA_RESTART) instead of the signal silently landing
// on some unrelated in-flight connection's worker thread.
import "proc";
import "net";
import "time";

extern fn getpid() -> i32;
extern fn kill(pid: i32, sig: i32) -> i32;

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn send_sigterm_soon() {
    time.sleep(150000000); // 150ms -- give main time to block in accept()
    let pid = getpid();
    kill(pid, 15); // SIGTERM, process-directed
}

fn handle_conn(cfd: i32) {
    time.sleep(100000000); // simulate in-flight work that must finish
    net.send(cfd, b"OK");
    net.close(cfd);
}

fn accept_and_serve(lfd: i32) -> int {
    let ar: result[i32, str] = net.accept(lfd);
    guard let sfd = ar else { return 0; }
    spawn handle_conn(sfd);
    return 1;
}

let lr: result[i32, str] = net.listen(0);
guard let lfd = lr else { die("listen"); }
let pr: result[i32, str] = net.port(lfd);
guard let port = pr else { die("port"); }

spawn send_sigterm_soon();

// connect one client before the signal fires, so main's first
// accept() returns immediately; the SECOND accept() call is the one
// blocked with nothing pending, and is the one that must observe the
// interruption
let dr: result[i32, str] = net.dial("127.0.0.1", port);
guard let cfd = dr else { die("dial"); }

let handled = 0;
while !proc.shutdown_requested() {
    handled = handled + accept_and_serve(lfd);
}
println("shutdown requested, loop exited");
println(to_str(handled));

let waited = 0;
while proc.active_tasks() > 0 {
    time.sleep(20000000);
    waited = waited + 1;
    if waited > 100 { die("drain timed out"); }
}
println("drained");

let rr: result[bytes, str] = net.recv(cfd, 16);
guard let data = rr else { die("client recv"); }
if data == b"OK" {
    println("client got full response");
} else {
    die("unexpected response");
}

net.close(cfd);
net.close(lfd);
println("proc_shutdown ok");
