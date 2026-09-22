// An error inside a generic function's body names the instance and the
// line that asked for it.
fn double_it[T](x: T) -> T {
    return x * 2;
}
struct Local { n: int }
fn f(l: Local) -> Local {
    return double_it(l);
}
println(f(Local { n: 1 }).n);
