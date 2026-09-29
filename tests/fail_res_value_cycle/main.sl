// A struct holding a result that holds it back, all by value,
// would need an infinitely large value: a compile error, not a hang.
struct S { r: result[S, int] }
let s = S { r: ok(S { r: err(1) }) };
println("unreachable");
