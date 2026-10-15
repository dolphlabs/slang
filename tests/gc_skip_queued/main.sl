// Minor collections skip queued tasks that have not run since two minors
// ago, the same as parked ones: under load nearly every connection of a
// busy server is queued, not parked. 2000 tasks park on channels, are all
// woken at once -- queued now, waiting their turn behind main on one
// worker -- and main allocates through many minors before yielding.
// tests/run_tests.sh reads SLANG_GC_STAT and checks most of those queued
// tasks were skipped; this checks every task still has its own value.

gc struct Note { n: int, text: str }

fn waiter(id: int, wake: chan[int], done: chan[int]) {
    let mine = Note { n: id, text: "note " + to_str(id) };
    let r = chan_recv(wake);
    guard let k = r else { chan_send(done, -1); return; }
    if mine.n != id || mine.text != "note " + to_str(id) || k != id {
        chan_send(done, -1);
        return;
    }
    chan_send(done, 1);
}

let n = 2000;
let done: chan[int] = make_chan(n);
let wakes: [chan[int]] = [];
let i = 0;
while i < n {
    let w: chan[int] = make_chan(1);
    push(wakes, w);
    spawn waiter(i, w, done);
    i = i + 1;
}
// Let every waiter run to its chan_recv and park.
let p = 0;
while p < 50 {
    let t: chan[int] = make_chan(1);
    chan_send(t, p);
    let _x = chan_recv(t);
    p = p + 1;
}
i = 0;
while i < n {
    chan_send(wakes[i], i);
    i = i + 1;
}
// All 2000 are queued now. Allocate through many minors before anything
// else runs.
let keep = 0;
let k = 0;
while k < 400000 {
    let s = "garbage " + to_str(k);
    keep = keep + len(s);
    k = k + 1;
}
let ok = 0;
i = 0;
while i < n {
    let r = chan_recv(done);
    if (r ?? -1) == 1 { ok = ok + 1; }
    i = i + 1;
}
println("ok " + to_str(ok) + " of " + to_str(n) + ", kept " + to_str(keep > 0));
