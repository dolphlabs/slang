fn f(xs: [str]) -> int { return len(xs); }
// [] becomes [str] here; a non-list parameter gives it no type at all
fn g(n: int) -> int { return n; }
println(g([]));
