// Every runnable task gets to run. 64 CPU-bound tasks -- many more than
// workers -- count loop iterations for 1.5 s, yielding at every quantum
// back onto the striped run queues. Each must make real progress.
//
// Workers used to scan the stripes starting from a fixed "own" stripe,
// hashed from their thread id; with 16 stripes and fewer workers, most
// stripes had no owner, and a task hashed into one waited until every
// owner found its own stripe empty. Here that meant 43 to 50 of the 64
// tasks never ran at all. In a server the same starvation was a p99.9
// of hundreds of milliseconds and requests timing out.
import "time";

// The work between clock reads keeps the time in slang code: async
// preemption declines a PC inside libc or the vDSO (clock_gettime), and
// the suite's preemption-alignment check needs these tasks preemptible.
fn spin(until_ns: int, out: chan[int]) {
    let n = 0;
    while (time.mono() as int) < until_ns {
        let k = 0;
        while k < 256 {
            n = n + (k % 3) + 1;
            k = k + 1;
        }
    }
    chan_send(out, n);
}

let tasks = 64;
let out: chan[int] = make_chan(tasks);
let until_ns = (time.mono() as int) + 1500000000;
let i = 0;
while i < tasks {
    spawn spin(until_ns, out);
    i = i + 1;
}
let lo = -1;
let hi = 0;
let j = 0;
while j < tasks {
    let v = chan_recv(out);
    guard let n = v else {
        println("FAIL: results channel closed");
        exit(1);
    }
    if lo < 0 || n < lo { lo = n; }
    if n > hi { hi = n; }
    j = j + 1;
}
// Fair is measured as 2-3x between the busiest and the least busy task;
// 50x leaves room for a loaded CI machine and still catches starvation
// (a starved task's count is 0).
if lo == 0 {
    println("FAIL: a task never ran (max " + to_str(hi) + " iterations)");
    exit(1);
}
if hi / lo > 50 {
    println("FAIL: uneven progress, min " + to_str(lo) + " max " + to_str(hi));
    exit(1);
}
println("all 64 tasks made progress");
