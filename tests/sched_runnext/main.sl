// A task woken by the running task runs next on the same worker (the
// runnext slot), but a chain of such hand-offs shares one time slice.
// Here 128 pairs ping-pong a token through channels -- each send wakes the
// partner into runnext -- alongside 16 CPU-bound spinners. Without the
// shared slice, a pair would keep its worker forever and, with more pairs
// than any machine has workers, the spinners would never run. Everything
// must progress. (A runnext that gave each hand-off a fresh slice fails
// this; checked when it was written.)
//
// 48 pairs, not 128: a spinner spawned behind every pair waits a round
// of the run queue for its first turn, and a round is about one 10 ms
// quantum per pair and spinner divided by the workers running tasks. 160
// tasks on one worker and main's thread made that round longer than the
// 1.5 s run, so late spinners starved with a correct scheduler (5 of 12
// runs on one worker; CI's macOS arm64 leg now and then). 64 tasks keep a
// round near a third of a second, and 48 pairs still outnumber any
// machine's workers, which is what catches a fresh-slice runnext.
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

let pairs = 48;
let spinners = 16;
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
