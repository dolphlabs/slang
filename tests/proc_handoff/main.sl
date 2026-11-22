// Handing listeners to a new process: proc.spawn_fds passes them as fds
// 3, 4, ... with LISTEN_FDS set; the child (this same program, run with
// "child") takes them with net.inherited() and accepts on the parent's
// ports. Also proc.wait_idle_until, the bounded drain.
import "net";
import "proc";
import "time";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn soon() -> until { return until_of(time.mono() + 10000000000); }

fn child() {
    let fds = net.inherited();
    if len(fds) != 2 { die("child got " + to_str(len(fds)) + " fds"); }
    if len(net.inherited()) != 0 { die("second inherited() not empty"); }
    if let _v = proc.getenv("LISTEN_FDS") { die("LISTEN_FDS left set"); }
    // one connection on each, answering with the fd it came in on
    for fd in fds {
        let ar = net.accept(fd);
        guard let c = ar else let e = err_of(ar) { die("child accept: " + e); }
        let _s = net.send(c, to_bytes("fd " + to_str(fd)));
        net.close(c);
    }
    exit(0);
}

fn read_all(fd: i32) -> str {
    let out = "";
    while true {
        let rr = net.recv_until(fd, 64, soon());
        guard let b = rr else { break; }
        if len(b) == 0 { break; }
        out = out + to_str(b);
    }
    return out;
}

fn sleeper(ns: int) {
    time.sleep(ns);
}

fn parent() {
    let l1 = net.listen(0) ?? (-1 as i32);
    let l2 = net.listen(0) ?? (-1 as i32);
    let p1 = net.port(l1) ?? 0;
    let p2 = net.port(l2) ?? 0;
    let args = proc.args();
    let noenv: [str] = [];
    // reversed, so l2 lands on 3 and l1 on 4
    let sr = proc.spawn_fds([args[0], "child"], noenv, "", 0, [l2, l1]);
    guard let pid = sr else let e = err_of(sr) { die("spawn_fds: " + e); }
    // the parent lets go; the ports stay open in the child
    net.close(l1);
    net.close(l2);
    let c2 = net.dial("127.0.0.1", p2) ?? (-1 as i32);
    let a2 = read_all(c2);
    net.close(c2);
    let c1 = net.dial("127.0.0.1", p1) ?? (-1 as i32);
    let a1 = read_all(c1);
    net.close(c1);
    if a2 != "fd 3" || a1 != "fd 4" { die("mapping: port2 -> " + a2 + ", port1 -> " + a1); }
    let wr = proc.wait(pid, soon());
    guard let code = wr else { die("wait"); }
    if code != 0 { die("child exit " + to_str(code)); }
    println("handoff: child accepted on both ports, fds 3 and 4 in order");

    let bad: [i32] = [999 as i32];
    let br = proc.spawn_fds([args[0], "child"], noenv, "", 0, bad);
    if let _p = br { die("closed fd accepted"); } else let be = err_of(br) { println(be); }
    let nofds: [i32] = [];
    let nr = proc.spawn_fds([args[0], "child"], noenv, "", 0, nofds);
    if let _q = nr { die("empty fds accepted"); } else let ne = err_of(nr) { println(ne); }
    if len(net.inherited()) != 0 { die("parent inherited something"); }

    // a drain with a deadline: too short, then long enough
    spawn sleeper(300000000);
    let t0 = time.mono();
    if proc.wait_idle_until(until_of(time.mono() + 50000000)) { die("idle while a task sleeps"); }
    if time.mono() - t0 < 40000000 { die("wait_idle_until returned early"); }
    if !proc.wait_idle_until(soon()) { die("never idle"); }
    if time.mono() - t0 < 250000000 { die("idle before the task finished"); }
    println("wait_idle_until: false at the deadline, then true");
}

let a = proc.args();
if len(a) > 1 && a[1] == "child" {
    child();
} else {
    parent();
}
