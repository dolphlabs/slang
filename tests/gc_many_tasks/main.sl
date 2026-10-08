// Many parked tasks, each holding live values, while four tasks
// allocate: enough root-bearing tasks that a collection's mark is split
// between the collector and the stopped threads (SL_GC_MARK_PARALLEL_MIN,
// todo.md R4). Every parked task checks its values when it is released.
// tests/run_tests.sh reads SLANG_GC_STAT for the mark joins.
import "strings";

fn parked(id: int, ch: chan[int]) -> int {
    let name = strings.repeat("p", 20) + to_str(id);
    let tags: [str] = [name + "-a", name + "-b"];
    let v = chan_recv(ch) ?? -1;
    if name != strings.repeat("p", 20) + to_str(id) || tags[0] != name + "-a" ||
       tags[1] != name + "-b" || v != id {
        return 1;
    }
    return 0;
}

fn churn(k: int) -> int {
    let t = 0;
    let i = 0;
    while i < k {
        let s = strings.repeat("x", 64) + to_str(i);
        t = t + len(s);
        i = i + 1;
    }
    return t;
}

let chans: [chan[int]] = [];
let tasks: [join[int]] = [];
let n = 0;
while n < 300 {
    let c: chan[int] = make_chan(1);
    push(chans, c);
    push(tasks, spawn parked(n, c));
    n = n + 1;
}
let ws: [join[int]] = [];
let w = 0;
while w < 4 { push(ws, spawn churn(60000)); w = w + 1; }
for h in ws { let r = join_wait(h); }
let i = 0;
for c in chans { chan_send(c, i); i = i + 1; }
let bad = 0;
for h in tasks { bad = bad + (join_wait(h) ?? 1); }
println("bad: " + to_str(bad));
