// spawn arguments that are calls returning GC values: an earlier one is
// live across a later one's call (which can allocate and collect), so
// it must be rooted from its spawn-args field. `spawn f(mk(), mk())`
// used to die in the compiler with "liveness-pending value has no
// registered temp". Run under a 16KB nursery and the minor verifier by
// tests/run_tests.sh, so an unrooted argument is freed and caught.

gc struct Box {
    label: str,
    parts: [int],
}

// a value struct carrying GC fields, passed by value
struct Pair {
    a: str,
    b: [int],
}

fn mk(i: int) -> Box {
    // allocate enough that a minor lands while the next argument runs
    let parts: [int] = [];
    let k = 0;
    while k < 64 {
        push(parts, i + k);
        k = k + 1;
    }
    return Box { label: "box" + to_str(i), parts: parts };
}

fn pair(i: int) -> Pair {
    return Pair { a: "pair" + to_str(i), b: [i, i + 1] };
}

fn sum(x: Box, y: Box) -> int {
    return len(x.label) + x.parts[63] + len(y.label) + y.parts[63];
}

fn sum3(x: Box, k: int, y: Box) -> int {
    return sum(x, y) + k;
}

fn sum_pair(p: Pair, x: Box, q: Pair) -> int {
    return len(p.a) + p.b[1] + x.parts[0] + len(q.a) + q.b[1];
}

fn record(x: Box, y: Box, out: chan[int]) {
    chan_send(out, sum(x, y));
}

fn with_link(x: Box, l: link, y: Box) -> int {
    return sum(x, y);
}

let total = 0;
let i = 0;
while i < 200 {
    let h1 = spawn sum(mk(i), mk(i + 1));
    total = total + (join_wait(h1) ?? -1000000);
    let h2 = spawn sum3(mk(i), 2, mk(i + 2));
    total = total + (join_wait(h2) ?? -1000000);
    let h3 = spawn sum_pair(pair(i), mk(i), pair(i + 3));
    total = total + (join_wait(h3) ?? -1000000);
    let out: chan[int] = make_chan(1);
    spawn record(mk(i), mk(i + 4), out);
    total = total + (chan_recv(out) ?? -1000000);
    i = i + 1;
}

let lr = link_listen(0);
guard let ln = lr else { println("FAIL listen"); exit(1); }
let dr = link_dial("127.0.0.1", ln.port(), until_never());
guard let c = dr else { println("FAIL dial"); exit(1); }
let hl = spawn with_link(mk(1), c, mk(2));
total = total + (join_wait(hl) ?? -1000000);

println("total " + to_str(total));
