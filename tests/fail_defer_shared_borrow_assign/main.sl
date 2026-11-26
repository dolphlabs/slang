fn read(x: &int) -> int {
    return *x;
}
fn f() -> int {
    let x = 1;
    defer read(&x);
    x = 2;
    return x;
}
println(f());
