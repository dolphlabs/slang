// A call's safepoint record must be complete before the task's chain
// points at it: an async preemption stops a task at any instruction, and
// the collector walks a preempted task's chain. gcc stored a record's
// root count after the store that published it, so a task preempted
// between the two had a record whose count was whatever the stack held
// before, and the collector read that many roots off the end of the
// stack (SIGSEGV in sl_gc_mark_task; seen once in ~2M requests on the PG
// bench, in pg's to_ready loop). The window is two instructions, too
// narrow to hit on demand: check.py, beside this, compiles this program
// and others and fails on any record published before its count. This
// program is the runtime side: 12 tasks on 4 workers run loops of that
// shape -- a result from one call, then a call with two roots -- under
// forced 1 ms preemption with a 16KB nursery and the minor verifier
// (tests/run_tests.sh), so minors land while tasks sit preempted.

struct Step {
    done: bool,
    n: int,
}

fn step(buf: [int], i: int) -> Step {
    push(buf, i);
    if len(buf) > 64 {
        return Step { done: true, n: len(buf) };
    }
    return Step { done: false, n: 0 };
}

fn note(tag: str, buf: [int]) -> str {
    return tag + to_str(len(buf));
}

fn spin(id: int, rounds: int, out: chan[int]) {
    let tag = "t" + to_str(id) + ":";
    let total = 0;
    let r = 0;
    while r < rounds {
        let buf: [int] = [];
        let i = 0;
        while true {
            let s = step(buf, i);
            if s.done {
                total = total + s.n;
                break;
            }
            let t = note(tag, buf);
            if len(t) == 0 {
                total = total - 1;
            }
            i = i + 1;
        }
        r = r + 1;
    }
    chan_send(out, total);
}

let tasks = 12;
let rounds = 3000;
let out: chan[int] = make_chan(tasks);
let k = 0;
while k < tasks {
    spawn spin(k, rounds, out);
    k = k + 1;
}
let bad = 0;
k = 0;
while k < tasks {
    let v = chan_recv(out) ?? -1;
    if v != rounds * 65 {
        bad = bad + 1;
    }
    k = k + 1;
}
println("ok " + to_str(tasks - bad) + " of " + to_str(tasks));
