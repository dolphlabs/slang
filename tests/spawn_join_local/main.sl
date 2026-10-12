// spawn directly followed by join_wait: the child is submitted without
// waking an idle worker (codegen marks the pair; runtime
// sl_task_submit_copy_joined), and the join's completion resumes the
// spawner without one either (sl_task_resume_local). Both rely on the
// worker that put the task in its runnext slot running it next, so this
// exercises every way that worker can stop running the spawner first:
// children that allocate (collections), panic (sl_join_fail), and run
// past their time slice (the chain's quantum ends and the slot goes to
// the shared queues). A task that never runs hangs the test.
// tests/run_tests.sh also checks SLANG_SCHED_STAT's runnext_wakes.

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
