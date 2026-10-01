// Allocations per redis round trip, for tests/run_tests.sh's budget: with
// ALLOC_BUDGET_N set it sends that many PINGs to an in-process server and
// nothing else. The client used to append every recv to its whole buffer
// and compact only past 1MB consumed, copying up to a megabyte per reply;
// now only the unconsumed tail is ever copied, and between replies there
// is none.
import "redis";
import "net";
import "proc";
import "time";

fn soon() -> until {
    return until_of(time.mono() + 5000000000);
}

// One connection; one +PONG per recv. The client waits for each reply
// before sending again, so every recv holds exactly one command.
fn serve(lfd: i32) {
    let ar = net.accept(lfd);
    guard let fd = ar else { exit(1); }
    while true {
        let rr = net.recv_until(fd, 4096, soon());
        guard let b = rr else { return; }
        if len(b) == 0 { return; }
        let sr = net.send_until(fd, b"+PONG\r\n", soon());
        guard let _n = sr else { return; }
    }
}

let lr = net.listen(0);
guard let lfd = lr else { println("FAIL listen"); exit(1); }
let pr = net.port(lfd);
guard let port = pr else { println("FAIL port"); exit(1); }
spawn serve(lfd);

let cr = redis.connect("redis://127.0.0.1:" + to_str(port), soon());
guard let c = cr else let e = err_of(cr) { println("FAIL connect: " + e); exit(1); }

let n = to_int(proc.getenv("ALLOC_BUDGET_N") ?? "-1") ?? -1;
let rounds = n;
if n < 0 { rounds = 1000; }
let i = 0;
while i < rounds {
    let r = redis.ping(c, soon());
    guard let s = r else let e = err_of(r) { println("FAIL ping: " + e); exit(1); }
    if s != "PONG" { println("FAIL reply " + s); exit(1); }
    i = i + 1;
}
redis.close(c);
if n < 0 { println("1000 pings ok"); }
