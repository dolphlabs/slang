// A channel that has become old, used as a queue for short-lived
// objects: each value is received at once, so none of them should
// outlive the young generation. A received value's slot used to keep
// its pointer until the ring came round to it again, and a collection
// traced every slot, live or not, so every value sent through an old
// channel was promoted.

gc struct Ev {
    n: int,
    tag: str,
}

fn churn(i: int) -> int {
    // About 1 KB of garbage per message, so young collections happen
    // far more often than the ring wraps.
    let s = "";
    let k = 0;
    while k < 8 {
        s = to_str(i) + "-padding-padding-padding-padding-padding-padding-" +
            "padding-padding-padding-padding-padding-padding-" + to_str(k);
        k = k + 1;
    }
    return len(s);
}

let ch: chan[Ev] = make_chan(4096);
// Age the channel: enough young collections that it is promoted.
let i = 0;
let total = 0;
while i < 20000 {
    total = total + churn(i) % 3;
    i = i + 1;
}
i = 0;
let sum = 0;
while i < 100000 {
    chan_send(ch, Ev { n: 1, tag: to_str(i) });
    let r = chan_recv(ch);
    guard let ev = r else {
        exit(1);
    }
    sum = sum + ev.n;
    total = total + churn(i) % 3;
    i = i + 1;
}
println(sum);

// Queued values must stay alive however the ring sits: 3,000 values
// across the wrap point (head is at 100000 % 4096 = 1696), held through
// many young collections, then received and checked one by one.
let j = 0;
while j < 3000 {
    chan_send(ch, Ev { n: j, tag: "q" + to_str(j) });
    j = j + 1;
}
j = 0;
while j < 3000 {
    total = total + churn(j) % 3;
    j = j + 1;
}
let bad = 0;
j = 0;
while j < 3000 {
    let r2 = chan_recv(ch);
    guard let q = r2 else {
        exit(1);
    }
    if q.n != j || q.tag != "q" + to_str(j) {
        bad = bad + 1;
    }
    j = j + 1;
}
println(bad);
println(total > 0);
