// m[k] = v is a safepoint -- the map may grow -- and its bracket used to
// root only the key and the value. A map referenced by nothing but a
// local was then freed by a collection landing at that bracket, and the
// next put wrote into memory another object had been given. httpc.run's
// per-request header map was the first victim. Hidden while the
// collector treated each task's recent allocations as roots.
//
// Run by the suite with SLANG_GC_THRESHOLD_KB=16, where collections are
// frequent enough to land at those brackets.

fn key(i: int) -> str {
    return "k" + to_str(i);
}

// Puts in sequence, NOT in a loop: a loop's own back-edge bracket roots
// the map and would hide the bug. Between two statements the map is in
// nothing but a C local, exactly as in httpc.run.
fn build(n: int) -> map[str]str {
    let m: map[str]str = {};
    m[key(n)] = "value " + to_str(n);
    m[key(n + 1)] = "value " + to_str(n + 1);
    m[key(n + 2)] = "value " + to_str(n + 2);
    m[key(n + 3)] = "value " + to_str(n + 3);
    m[key(n + 4)] = "value " + to_str(n + 4);
    m[key(n + 5)] = "value " + to_str(n + 5);
    m[key(n + 6)] = "value " + to_str(n + 6);
    m[key(n + 7)] = "value " + to_str(n + 7);
    m[key(n + 8)] = "value " + to_str(n + 8);
    m[key(n + 9)] = "value " + to_str(n + 9);
    return m;
}

let round = 0;
while round < 30000 {
    let m = build(round);
    if len(m) != 10 {
        println("FAIL size " + to_str(len(m)));
        exit(1);
    }
    let i = 0;
    while i < 10 {
        if m[key(round + i)] != "value " + to_str(round + i) {
            println("FAIL entry " + to_str(i) + " in round " + to_str(round));
            exit(1);
        }
        i = i + 1;
    }
    round = round + 1;
}
println("PASS");
