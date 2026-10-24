// Each generated function resolves its task once (SL_SELF, sl_core.c) and
// every bracket in it reuses that pointer instead of reading the TLS slot
// twice. Correctness rests on a function running on one task however
// often it is preempted, parked and resumed on another worker; these
// tasks allocate on every iteration and run under the GC stress lists and
// forced 1 ms preemption, so they are moved mid-function while holding the
// pointer. run_tests.sh also checks the generated C: no emitted bracket
// reads the task on its own any more.
import "time";

fn build(n: int, tag: str) -> [str] {
    let out: [str] = [];
    for i in 0..n {
        push(out, tag + " " + to_str(i));
    }
    return out;
}

fn churn(id: int, rounds: int) -> int {
    let total = 0;
    let keep: [str] = [];
    for r in 0..rounds {
        let xs = build(40, "task " + to_str(id));
        total = total + len(xs[r % 40]);
        if r % 16 == 0 {
            push(keep, xs[0]);
            time.sleep(1000);
        }
    }
    return total + len(keep);
}

let handles: [join[int]] = [];
for t in 0..8 {
    push(handles, spawn churn(t, 400));
}
let sum = 0;
for h in handles {
    let r = join_wait(h);
    guard let v = r else let e = err_of(r) {
        println("task failed: " + e);
        exit(1);
    }
    sum = sum + v;
}
println(sum);
