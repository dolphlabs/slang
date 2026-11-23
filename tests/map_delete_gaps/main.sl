// A map delete leaves a gap in the insertion-order array instead of
// shifting every later entry down; gaps are squeezed out when the array
// fills or the map grows. Everything that walks a map in order must skip
// gaps and keep insertion order: for-in, json.encode and inspect, before
// and after a squeeze, after deleting everything, and when the loop body
// deletes the key it is on.

import "json";

fn fail(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

// Small maps print in full, so gaps show up in the output if mishandled.
let m: map[str]int = {"a": 1, "b": 2, "c": 3, "d": 4, "e": 5};
del(m, "b");
del(m, "d");
println(json.encode(m));
println(inspect(m));
let seen = "";
for k, v in m {
    seen = seen + k + to_str(v);
}
println(seen);

// Reinserting a deleted key puts it at the end.
m["b"] = 20;
println(json.encode(m));

// Delete everything, then reuse the map.
del(m, "a");
del(m, "c");
del(m, "e");
del(m, "b");
println(len(m));
println(json.encode(m));
println(inspect(m));
m["z"] = 26;
m["y"] = 25;
println(json.encode(m));

// Churn at a steady size: each round deletes the oldest keys and appends
// new ones, so the order array fills with gaps and is squeezed many times
// without the map growing. Iteration must still be insertion order.
let c: map[int]int = {};
let next_key = 0;
let oldest = 0;
for i in 0..50 {
    c[next_key] = next_key * 3;
    next_key += 1;
}
for round in 0..400 {
    for i in 0..7 {
        del(c, oldest);
        oldest += 1;
    }
    for i in 0..7 {
        c[next_key] = next_key * 3;
        next_key += 1;
    }
    let want = oldest;
    for k, v in c {
        if k != want || v != k * 3 {
            fail("churn order at round " + to_str(round) + ": key " + to_str(k) + " wanted " + to_str(want));
        }
        want += 1;
    }
    if want != next_key || len(c) != 50 {
        fail("churn size at round " + to_str(round));
    }
}
println("churn ok " + to_str(len(c)) + " " + to_str(oldest) + ".." + to_str(next_key));

// Deleting the key the loop is on: every other key is still visited once.
let d: map[int]int = {};
for i in 0..100 {
    d[i] = i;
}
let visits = 0;
let total = 0;
for k, v in d {
    visits += 1;
    total += v;
    if k % 2 == 0 {
        del(d, k);
    }
}
println("visited " + to_str(visits) + " total " + to_str(total) + " left " + to_str(len(d)));
let left = 0;
for k, _ in d {
    if k % 2 == 0 {
        fail("even key survived " + to_str(k));
    }
    left += 1;
}
println(left);
