// Parked tasks that stay parked across many minor collections hold young
// data, check it when woken, make new young data and park again. A minor
// may skip a parked task's roots only once two minors have scanned it
// since it last ran (everything it holds is old by then); skipping after
// one would free a string it allocated just before parking and has seen
// survive only once. tests/run_tests.sh also requires the skip to happen.
import "strings";

fn idle(id: int, ch: chan[int]) -> int {
    let bad = 0;
    let round = 0;
    let mine: [str] = [];
    let k = 0;
    while k < 4 { push(mine, strings.repeat("i", 24) + to_str(id * 100 + k)); k = k + 1; }
    while true {
        let v = chan_recv(ch) ?? -1;
        if v < 0 { break; }
        let j = 0;
        while j < 4 {
            if mine[j] != strings.repeat("i", 24) + to_str(id * 100 + round * 10 + j) { bad = bad + 1; }
            j = j + 1;
        }
        round = round + 1;
        mine = [];
        j = 0;
        while j < 4 { push(mine, strings.repeat("i", 24) + to_str(id * 100 + round * 10 + j)); j = j + 1; }
    }
    return bad;
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
let idles: [join[int]] = [];
let n = 0;
while n < 200 {
    let c: chan[int] = make_chan(1);
    push(chans, c);
    push(idles, spawn idle(n, c));
    n = n + 1;
}
let round = 0;
while round < 8 {
    let ws: [join[int]] = [];
    let w = 0;
    while w < 4 { push(ws, spawn churn(40000)); w = w + 1; }
    for h in ws { let r = join_wait(h); }
    // wake every task once: each checks what it built last round
    for c in chans { chan_send(c, round); }
    round = round + 1;
}
for c in chans { chan_send(c, -1); }
let bad = 0;
for h in idles { bad = bad + (join_wait(h) ?? 1); }
println("bad: " + to_str(bad));
