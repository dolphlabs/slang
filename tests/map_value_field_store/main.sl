// m[k].f = v stores into the map's value in place (it was refused with a
// slang error, and a C compile error before that), through nested value
// structs and with compound assignment. The late stores put young strings
// into a map aged old by earlier collections: the run_tests.sh minor
// verifier fails if the store's barrier is missing.
struct In { tag: str, n: int }
struct P { x: int, name: str, inner: In }
let m: map[str]P = {"a": P { x: 1, name: "a", inner: In { tag: "t", n: 0 } }};
m["a"].x = 2;
m["a"].name = "renamed " + to_str(m["a"].x);
m["a"].inner.tag = "deep";
m["a"].inner.n += 5;
println(to_str(m["a"].x) + " " + m["a"].name + " " + m["a"].inner.tag + " " + to_str(m["a"].inner.n));
let ids: map[int]P = {};
for i in 0..1000 {
    ids[i] = P { x: i, name: "", inner: In { tag: "", n: 0 } };
}
for i in 0..1000 {
    ids[i].name = "n" + to_str(i);
}
println(ids[999].name + " " + ids[0].name + " " + to_str(len(ids)));
let junk: [str] = [];
for r in 0..30 {
    for i in 0..1000 {
        push(junk, "j" + to_str(i));
    }
    junk = [];
}
for i in 0..1000 {
    ids[i].name = "late" + to_str(i * 3);
    for j in 0..20 { push(junk, "x" + to_str(j)); }
    junk = [];
}
let ok = 0;
for i in 0..1000 {
    if ids[i].name == "late" + to_str(i * 3) { ok += 1; }
}
println(ok);

// the value grows the map (rehashing every slot) before the store's
// address is taken
fn fill(m: map[int]P, n: int) -> int {
    for i in 1000..n {
        m[i] = P { x: i, name: "", inner: In { tag: "", n: 0 } };
    }
    return len(m);
}
ids[5].x = fill(ids, 5000);
println(to_str(ids[5].x) + " " + to_str(ids[4999].x) + " " + ids[5].name);
