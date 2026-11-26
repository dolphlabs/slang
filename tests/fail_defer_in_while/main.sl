fn step(i: int) {
    let _ = i;
}
fn f() {
    let i = 0;
    while i < 3 {
        defer step(i);
        i += 1;
    }
}
f();
