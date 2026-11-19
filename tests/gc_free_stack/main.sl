// A collection that starts at a safepoint near the bottom of a task's stack.
//
// A safepoint promises SL_TASK_GUARD_MARGIN (2KB) below it, and the collector
// used to run there, on the task's stack, free() calls and all. On macOS
// x86_64, free() of a small-zone block (about 1KB to 32KB) needs 4.4KB of
// stack when its magazine passes its free-space limit: libmalloc moves a
// region to the depot and scans it with a 4KB array on the stack. Each task
// here dives to a different depth, so collections begin at every distance
// from the margin, and keeps 150 such blocks alive until they all die at
// once, which is what pushes a magazine over the limit. With collections
// 128MB apart (run_tests.sh, "collector stack") the old runtime died in the
// guard page in 8 of 10 runs. The collector now runs on the worker's own
// stack (sl_rt_gc_checkin_slow).
import "strings";

fn churn(seed: int) -> int {
    let keep: [bytes] = [];
    for i in 0..150 {
        let n = 4100 + ((seed * 131 + i * 977) % 26000);
        push(keep, strings.bytes_zero(n));
    }
    return len(keep);
}

fn dive(depth: int, seed: int) -> int {
    if depth == 0 {
        return churn(seed);
    }
    let pad = [depth, seed, depth + seed];
    return dive(depth - 1, seed) + len(pad) - 3;
}

fn worker(id: int) -> int {
    let total = 0;
    for round in 0..4 {
        total = total + dive((id * 7 + round * 3) % 60, id + round);
    }
    return total;
}

let hs: [join[int]] = [];
for id in 0..32 {
    push(hs, spawn worker(id));
}
let sum = 0;
for h in hs {
    sum = sum + (join_wait(h) ?? 0);
}
println(sum);
