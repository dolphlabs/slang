// Fan-out FROM a worker -- the workload work-stealing actually exists
// to fix, and the one concurrent_compute cannot exercise by
// construction.
//
// concurrent_compute does all of its spawning in one loop at TOP
// LEVEL, i.e. on main's own original OS thread, which has no local run
// queue of its own (slot_idx == -1) and therefore pushes every task to
// the shared global queue -- exactly the pre-work-stealing behaviour.
// It would pass without exercising a single local-queue push or steal.
//
// Here the root task is itself spawned FIRST, so it runs on a real
// pool worker (slot_idx >= 0), and only THEN does its own spawn loop.
// Every child therefore lands on that one worker's local queue, giving
// the "one hot local queue, N-1 idle workers" pathology stealing is
// for. If stealing did not work, one worker would run all WF_TASKS
// tasks serially while the rest sat idle.
//
//   WF_TASKS -- number of children fanned out (default 2000)
//   WF_WORK  -- per-child CPU work: counts primes in [0, WF_WORK)
//               (default 3000)

import "time";
import "proc";

extern fn atoi(s: str) -> i32;

fn count_primes_range(hi: int) -> int {
    let count = 0;
    for i in 0..hi {
        let is_prime = true;
        if i < 2 { is_prime = false; }
        let d = 2;
        while d * d <= i {
            if i % d == 0 { is_prime = false; }
            d = d + 1;
        }
        if is_prime { count = count + 1; }
    }
    return count;
}

fn child(out: chan[int], work: int) {
    chan_send(out, count_primes_range(work));
}

// The root task: runs on a real pool worker, fans out from there.
fn fanout_root(out: chan[int], n: int, work: int) {
    let i = 0;
    while i < n {
        spawn child(out, work);
        i = i + 1;
    }
}

let tasks_str: str = proc.getenv("WF_TASKS") ?? "2000";
let tasks: int = atoi(tasks_str) as int;
let work_str: str = proc.getenv("WF_WORK") ?? "3000";
let work: int = atoi(work_str) as int;

let results: chan[int] = make_chan(256);

let t0 = time.mono();
spawn fanout_root(results, tasks, work);

let total = 0;
let got = 0;
while got < tasks {
    total = total + (chan_recv(results) ?? 0);
    got = got + 1;
}
let elapsed = time.mono() - t0;

// Drain: every child plus the root must have finished.
while proc.active_tasks() > 0 {
    time.sleep(1000000);
}

println("tasks=" + to_str(tasks) + " work=" + to_str(work));
println("total_primes=" + to_str(total));
println("elapsed_ms=" + to_str(elapsed / 1000000));
println("active_tasks_after=" + to_str(proc.active_tasks()));
