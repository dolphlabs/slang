// Threads stopped for a collection sleep through the pause instead of
// spinning. Four tasks allocate on four workers, so each minor finds the
// other workers running and stops them; tests/run_tests.sh ("stopped
// threads sleep") reads SLANG_GC_STAT's stw line and requires sleeps.
// They used to call sched_yield in a loop for the whole pause: a
// syscall per turn, 60% of the quote server's CPU on Linux.
import "strings";

fn churn(id: int) -> int {
    let total = 0;
    let i = 0;
    while i < 60000 {
        let s = strings.repeat("x", 64) + to_str(i * id);
        total = total + len(s);
        i = i + 1;
    }
    return total;
}

let hs: [join[int]] = [];
let k = 1;
while k <= 4 {
    push(hs, spawn churn(k));
    k = k + 1;
}
let sum = 0;
for h in hs {
    sum = sum + (join_wait(h) ?? 0);
}
println("total: " + to_str(sum));
