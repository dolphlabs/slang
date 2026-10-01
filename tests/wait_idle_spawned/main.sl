// proc.wait_idle() / proc.active_tasks() called from a spawned task do
// not count the caller. They used to: a task that waited for idle waited
// for itself and never returned (every test under `slangc test` runs in a
// spawned task, so a drain test hung forever).
import "proc";
import "time";

gc struct Tally {
    lock: mutex,
    done: int,
}

fn work(t: Tally, ms: int) {
    time.sleep(ms * 1000000);
    mutex_lock(t.lock);
    t.done = t.done + 1;
    mutex_unlock(t.lock);
}

fn gated(t: Tally, gate: chan[int]) {
    let _v = chan_recv(gate);
    mutex_lock(t.lock);
    t.done = t.done + 1;
    mutex_unlock(t.lock);
}

// Spawns workers, then waits for them from inside a spawned task.
fn coordinator(t: Tally, n: int, alone: bool) -> int {
    if alone && proc.active_tasks() != 0 {
        println("FAIL: active_tasks counted the caller: " + to_str(proc.active_tasks()));
        exit(1);
    }
    for i in 0..n {
        spawn work(t, 20 + i * 5);
    }
    proc.wait_idle();
    let seen = proc.active_tasks();
    mutex_lock(t.lock);
    let d = t.done;
    mutex_unlock(t.lock);
    if alone && seen != 0 {
        println("FAIL: active_tasks after wait_idle: " + to_str(seen));
        exit(1);
    }
    return d;
}

let t = Tally { lock: make_mutex(), done: 0 };
let j = spawn coordinator(t, 3, true);
println("coordinator saw " + to_str(join_wait(j) ?? -1) + " done");

// Two spawned tasks waiting for idle at the same time release each
// other once the real work is gone, instead of each waiting on the other.
let t2 = Tally { lock: make_mutex(), done: 0 };
let a = spawn coordinator(t2, 2, false);
let b = spawn coordinator(t2, 2, false);
let ra = join_wait(a) ?? -1;
let rb = join_wait(b) ?? -1;
println("two waiters returned: " + to_str(ra >= 2 && rb >= 2));

// From main nothing changed: every spawned task counts, and wait_idle
// returns once all of them are done. The workers wait on a gate so the
// count is not a race against their sleep.
let gate: chan[int] = make_chan(2);
spawn gated(t, gate);
spawn gated(t, gate);
println("main sees " + to_str(proc.active_tasks()) + " active");
chan_send(gate, 1);
chan_send(gate, 2);
proc.wait_idle();
println("main after wait_idle: " + to_str(proc.active_tasks()) + " active");
mutex_lock(t.lock);
println("total done " + to_str(t.done));
mutex_unlock(t.lock);
