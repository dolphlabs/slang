// proc.wait across a shutdown signal. SIGTERM wakes every parked task
// (sl_reactor_kick) so that loops polling proc.shutdown_requested() run,
// and a proc.wait parked on a child's exit was woken too. It found the
// child still running and returned "proc.wait: wait failed"; zokor's
// watcher took that for its server crashing, forgot the server, and left it
// running in its own process group after Ctrl-C. A wake is not an exit: the
// wait must go on and return the child's real exit status.
import "proc";
import "time";

extern fn getpid() -> i32;
extern fn kill(pid: i32, sig: i32) -> i32;

fn send_term_soon() {
    time.sleep(200000000);
    let _k = kill(getpid(), 15);
}

let empty: [str] = [];
let sr = proc.spawn(["sh", "-c", "sleep 1; exit 7"], empty, "", proc.SPAWN_GROUP);
guard let pid = sr else let e = err_of(sr) {
    println("FAIL spawn: " + e);
    exit(1);
}
spawn send_term_soon();
let t0 = time.mono();
let wr = proc.wait(pid, until_never());
guard let code = wr else let e = err_of(wr) {
    println("FAIL proc.wait returned an error while the child still ran: " + e);
    exit(1);
}
println("child exit code " + to_str(code));
println("shutdown requested " + to_str(proc.shutdown_requested()));
println("waited for the exit " + to_str(time.mono() - t0 >= 700000000));
