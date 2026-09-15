// wrong argument count through a function value
fn double(x: int) -> int { return x * 2; }
let f: fn(int) -> int = double;
println(f(1, 2));
