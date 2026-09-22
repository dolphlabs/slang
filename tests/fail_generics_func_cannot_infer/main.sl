fn zero_of[T](n: int) -> int { return n; }
struct Nope { n: int }
fn make_nope[T]() -> Nope { return Nope { n: 1 }; }
println(make_nope());
