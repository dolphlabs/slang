// A map value is a copy; a field store into it is refused, not miscompiled.
struct P { x: int }
let m: map[str]P = {"a": P { x: 1 }};
m["a"].x = 2;
println(m["a"].x);
