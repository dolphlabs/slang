// a function value must match the fn type exactly
fn takes_str(s: str) -> int { return len(s); }
let f: fn(int) -> int = takes_str;
println(f(1));
