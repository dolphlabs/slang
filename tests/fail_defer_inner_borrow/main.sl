fn read(x: &int) -> int {
    return *x;
}
fn f(cond: bool) {
    if cond {
        let x = 10;
        defer read(&x);
    }
}
f(true);
