// No such method, on a receiver that is a call's result. This used to say
// "struct 'P' has no field 'nope'", which is not what was asked for.
struct P { x: int }
fn make() -> P { return P { x: 1 }; }
println(make().nope());
