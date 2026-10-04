// Arenas larger than the runtime's chunk free list are given back with
// free(), which takes the allocator's large-block lock. That free ran
// outside a preempt bracket, so a task async-preempted inside it sat
// queued holding the lock, and the next thread to allocate a large block
// -- the collector building its tables, say -- blocked for good (or, on
// Darwin, the unlock from another thread trapped). Here tasks churn
// 400 KB arenas while others allocate enough to collect constantly; the
// program must finish. Under forced preemption plain dev hung in 6 of 10
// runs.
import "strings";

fn churn(rounds: int) -> int {
    let used = 0;
    let r = 0;
    while r < rounds {
        let a = arena_new(400000);
        let w = a.wire(1000);
        used = used + len(w);
        r = r + 1;
    }
    return used;
}

fn garbage(rounds: int) -> int {
    let total = 0;
    let keep: [str] = [];
    let r = 0;
    while r < rounds {
        let s = strings.repeat("y", 300) + to_str(r);
        push(keep, s);
        if len(keep) > 32 {
            keep = [];
        }
        total = total + len(s);
        r = r + 1;
    }
    return total;
}

let hs: [join[int]] = [];
let k = 0;
while k < 6 {
    push(hs, spawn churn(40000));
    push(hs, spawn garbage(600000));
    k = k + 1;
}
let total = 0;
for h in hs {
    let r = join_wait(h);
    guard let v = r else {
        println("task failed");
        exit(1);
    }
    total = total + v;
}
println("total: " + to_str(total));
