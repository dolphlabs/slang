// A field store into a missing key fails as reading m[k] does.
struct P { x: int }
let m: map[str]P = {"a": P { x: 1 }};
m["a"].x = 2;
println(m["a"].x);
m["b"].x = 3;
