// A wait that ends by its deadline leaves its fd's one-shot registration
// armed. When that fd later becomes readable, the stale event names the
// task, which by then waits on another fd in another waiter list: it was
// unlinked from the wrong list, resumed for nothing, and on its next
// wait linked into its own list twice -- a cycle the reactor walked
// forever while holding that list's lock (the say login-flood hang).
import "net";
import "time";

// The reactor's shard for an fd (sl_reactor_wq_for), so the two
// connections are picked to land in different waiter lists.
fn shard(fd: int) -> int {
    let u = fd;
    u = u ^ (u >> 16);
    u = (u * 2654435761) % 4294967296;
    u = u ^ (u >> 13);
    return u % 16;
}

fn watchdog(ms: int) {
    time.sleep(ms * 1000000);
    println("FAIL reactor wedged: a wait never returned");
    exit(1);
}

fn later(fd: int, ms: int, msg: bytes) {
    time.sleep(ms * 1000000);
    let _s = net.send(fd, msg);
}

fn conn(lfd: int, port: int) -> [int] {
    let dr = net.dial("127.0.0.1", port);
    guard let c = dr else let e = err_of(dr) { println("dial: " + e); exit(1); }
    let ar = net.accept(lfd);
    guard let s = ar else let e = err_of(ar) { println("accept: " + e); exit(1); }
    return [c as int, s as int];
}

spawn watchdog(5000);
let lr = net.listen(0);
guard let lfd = lr else let e = err_of(lr) { println("listen: " + e); exit(1); }
let pr = net.port(lfd);
guard let port = pr else { println("port"); exit(1); }

let a = conn(lfd, port);
let b = conn(lfd, port);
let tries = 0;
while shard(b[0]) == shard(a[0]) && tries < 32 {
    b = conn(lfd, port);
    tries += 1;
}

for round in 0..3 {
    // 1. Time out on a: its registration stays armed.
    let t = net.recv_until(a[0], 16, until_of(time.mono() + 20000000));
    if let _got = t {
        println("FAIL a was not idle");
        exit(1);
    }
    // 2. Wait on b; meanwhile a turns readable (the stale event), then b.
    spawn later(a[1], 50, b"x");
    spawn later(b[1], 150, b"y");
    let got_b = net.recv_until(b[0], 16, until_of(time.mono() + 2000000000));
    guard let yb = got_b else let e = err_of(got_b) { println("FAIL recv b: " + e); exit(1); }
    if yb != b"y" {
        println("FAIL b gave the wrong bytes");
        exit(1);
    }
    let got_a = net.recv_until(a[0], 16, until_of(time.mono() + 2000000000));
    guard let xa = got_a else { println("FAIL recv a"); exit(1); }
    if xa != b"x" {
        println("FAIL a gave the wrong bytes");
        exit(1);
    }
}
println("reactor ignores stale events");
