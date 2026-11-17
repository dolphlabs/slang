// Busy workers whose minors are mostly the rendezvous grow the nursery,
// though almost nothing survives. Four tasks churn short strings on four
// workers; tests/run_tests.sh pins them to one CPU, where a minor waits
// for each descheduled worker to run again, and reads the nursery the
// run ended on from SLANG_GC_STAT. The nursery used to grow only when a
// minor found an eighth of it live, so this program stayed at 512 KB and
// paid the wait every 512 KB. On one worker there is no one to wait for,
// and it must stay there.
import "strings";

fn churn(id: int) -> int {
    let total = 0;
    let i = 0;
    while i < 150000 {
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
