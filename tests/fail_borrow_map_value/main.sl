// A map value has no stable address; borrowing it is refused, not miscompiled.
struct P { x: int }
fn get(p: &P) -> int { return p.x; }
let m: map[str]P = {"a": P { x: 1 }};
println(get(&m["a"]));
