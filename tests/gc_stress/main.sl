// Tier 10: forces real, repeated collections against actual generated
// code -- 'kept' stays rooted across a heavy stress loop that
// deliberately generates far more garbage than it retains (structs
// with string fields, maps with string keys, nested lists), including
// an unreachable reference cycle (via opt[Node] self-ish reference)
// discarded every round. If any collection swept something still
// reachable, the checksum below would be wrong or the program would
// crash; if the collector leaked mark bits or corrupted the free list
// across cycles, later rounds would misbehave even if earlier ones
// looked fine.

struct Node {
    val: int,
    tag: str,
    next: opt[Node],
}

fn checksum(xs: [Node]) -> int {
    let total = 0;
    for n in xs {
        total = total + n.val + len(n.tag);
    }
    return total;
}

let kept: [Node] = [];
let i = 0;
while i < 3000 {
    push(kept, Node { val: i, tag: "kept" + to_str(i), next: none });
    i = i + 1;
}

let round = 0;
while round < 600 {
    // heavy, discarded-every-round allocation: a junk list of structs
    // (each carrying a string field), a junk map with string keys, and
    // a two-node unreachable cycle (nothing outside this block ever
    // references either node once the round ends).
    let junk: [Node] = [];
    let j = 0;
    while j < 300 {
        push(junk, Node { val: round * 10000 + j, tag: "junk" + to_str(j), next: none });
        j = j + 1;
    }

    let m: map[str]int = {};
    let k = 0;
    while k < 80 {
        m["key" + to_str(k)] = k * (round + 1);
        k = k + 1;
    }

    let a = Node { val: -1, tag: "cyc-a", next: none };
    let b = Node { val: -2, tag: "cyc-b", next: some(a) };
    // 'a' and 'b' both go out of scope at the end of this iteration,
    // with only b -> a as a live reference while they're alive here --
    // not even a true cycle, but neither is ever added to 'kept', so
    // both must be reclaimed by a later collection. Referenced once
    // more here so nothing treats them as dead code to optimize away.
    if len(m) < 0 { println(b.tag); }

    round = round + 1;
}

println(checksum(kept));
println(len(kept));
println(kept[0].val);
println(kept[0].tag);
println(kept[2999].val);
println(kept[2999].tag);
println("done");
