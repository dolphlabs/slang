// spawn directly followed by join_wait: codegen marks the pair, and the
// child runs in place on the spawner (sl_protect_run) rather than as a
// task of its own. This exercises what the in-place call has to survive:
// children that allocate (collections), panic (the join fails and the
// spawner carries on), and run past their time slice (preempted inside
// the call). tests/run_tests.sh also checks SLANG_SCHED_STAT's submits.

import "time";

gc struct Work {
    n: int,
    label: str,
    parts: [int],
}

fn child(i: int) -> int {
    if i % 500 == 499 {
        panic("child " + to_str(i) + " failed on purpose");
    }
    if i % 1500 == 7 {
        // past the 10 ms quantum, so the chain has spent its slice
        let t0 = time.mono();
        while time.mono() - t0 < 30000000 {
        }
    }
    let w = Work { n: i, label: "w" + to_str(i), parts: [i, i + 1, i + 2] };
    return w.n + len(w.label) - len(w.label) + w.parts[2] - 2;
}

fn driver(id: int, rounds: int) -> int {
    let sum = 0;
    let panics = 0;
    let i = 0;
    while i < rounds {
        if i % 2 == 0 {
            let h = spawn child(i);
            let r = join_wait(h);
            guard let v = r else {
                panics = panics + 1;
                i = i + 1;
                continue;
            }
            sum = sum + v;
        } else {
            let r2 = join_wait(spawn child(i));
            guard let v2 = r2 else {
                panics = panics + 1;
                i = i + 1;
                continue;
            }
            sum = sum + v2;
        }
        i = i + 1;
    }
    return sum * 1000 + panics;
}

let drivers = 4;
let rounds = 3000;
let hs: [join[int]] = [];
let d = 0;
while d < drivers {
    push(hs, spawn driver(d, rounds));
    d = d + 1;
}
let total = 0;
for h in hs {
    let r = join_wait(h);
    guard let v = r else {
        println("FAIL a driver panicked");
        exit(1);
    }
    total = total + v;
}
println("total " + to_str(total));
