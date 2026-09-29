// A task woken by the running task runs next on the same worker (the
// runnext slot), but a chain of such hand-offs shares one time slice.
// Here 128 pairs ping-pong a token through channels -- each send wakes the
// partner into runnext -- alongside 32 CPU-bound spinners. Without the
// shared slice, a pair would keep its worker forever and, with more pairs
// than any machine has workers, the spinners would never run. Everything
// must progress. (A runnext that gave each hand-off a fresh slice fails
// this; checked when it was written.)
import "time";

fn pinger(until_ns: int, to: chan[int], from: chan[int], out: chan[int]) {
    let n = 0;
    while (time.mono() as int) < until_ns {
        chan_send(to, n);
        let v = chan_recv(from);
        guard let _got = v else { break; }
        n = n + 1;
    }
    chan_send(to, -1);
    chan_send(out, n);
}

fn ponger(from: chan[int], to: chan[int]) {
    while true {
        let v = chan_recv(from);
        guard let x = v else { return; }
        if x < 0 { return; }
        chan_send(to, x);
    }
}

fn spin(until_ns: int, out: chan[int]) {
    let n = 0;
    while (time.mono() as int) < until_ns {
        n = n + 1;
    }
    chan_send(out, n);
}

let pairs = 128;
let spinners = 32;
let until_ns = (time.mono() as int) + 1500000000;
let pair_out: chan[int] = make_chan(pairs);
let spin_out: chan[int] = make_chan(spinners);
let i = 0;
while i < pairs {
    let a: chan[int] = make_chan(1);
    let b: chan[int] = make_chan(1);
    spawn ponger(a, b);
    spawn pinger(until_ns, a, b, pair_out);
    i = i + 1;
}
i = 0;
while i < spinners {
    spawn spin(until_ns, spin_out);
    i = i + 1;
}
let ok = true;
i = 0;
while i < spinners {
    let v = chan_recv(spin_out);
    guard let n = v else { exit(1); }
    if n == 0 { ok = false; }
    i = i + 1;
}
i = 0;
while i < pairs {
    let v = chan_recv(pair_out);
    guard let n = v else { exit(1); }
    if n == 0 { ok = false; }
    i = i + 1;
}
if !ok {
    println("FAIL: a task made no progress");
    exit(1);
}
println("every pair and spinner made progress");
