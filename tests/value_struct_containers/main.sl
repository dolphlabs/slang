// Value structs whose pointer is not their first word, held by every
// container kind: a list, a map's values, a channel, a task's join. Two
// bugs freed their strings while still in use:
//  - the runtime's slot tracers took a container's nonzero "has pointers"
//    flag to mean "each slot is one pointer" and marked only a slot's
//    first word -- here the int (list: 19,917 of 20,000 elements wrong at
//    default settings; channel and join likewise);
//  - `m[k] = v` rooted v at its safepoint only when v was itself a GC
//    pointer, so a value struct's str was not rooted at all (map: 20,000
//    of 20,000 wrong).
struct P {
    n: int,
    s: str,
}

fn label(i: int) -> str {
    return "item-" + to_str(i);
}

fn make(i: int) -> P {
    return P { n: i, s: label(i) };
}

fn churn(rounds: int) -> int {
    let k = 0;
    let r = 0;
    while r < rounds {
        let junk = "garbage-" + to_str(r);
        k = k + len(junk);
        r = r + 1;
    }
    return k;
}

let ps: [P] = [];
let m: map[str]P = {};
let i = 0;
while i < 20000 {
    push(ps, P { n: i, s: label(i) });
    m[to_str(i)] = P { n: i, s: label(i) };
    i = i + 1;
}
let ch: chan[P] = make_chan(2000);
let c = 0;
while c < 2000 {
    chan_send(ch, P { n: c, s: label(c) });
    c = c + 1;
}
let hs: [join[P]] = [];
let t = 0;
while t < 200 {
    push(hs, spawn make(t));
    t = t + 1;
}
let burn = churn(200000);

let bad_list = 0;
for p in ps {
    if p.s != label(p.n) { bad_list = bad_list + 1; }
}
let bad_map = 0;
let j = 0;
while j < 20000 {
    let p = m[to_str(j)];
    if p.s != label(j) { bad_map = bad_map + 1; }
    j = j + 1;
}
let bad_chan = 0;
let r = 0;
while r < 2000 {
    let v = chan_recv(ch);
    guard let p = v else {
        println("channel closed early");
        exit(1);
    }
    if p.s != label(p.n) { bad_chan = bad_chan + 1; }
    r = r + 1;
}
let bad_join = 0;
for h in hs {
    let res = join_wait(h);
    guard let p = res else {
        println("task failed");
        exit(1);
    }
    if p.s != label(p.n) { bad_join = bad_join + 1; }
}
println("burn: " + to_str(burn > 0));
println("list: " + to_str(bad_list) + " bad");
println("map: " + to_str(bad_map) + " bad");
println("chan: " + to_str(bad_chan) + " bad");
println("join: " + to_str(bad_join) + " bad");
