fn step(i: int) {
    let _ = i;
}
fn f() {
    for i in 0..3 {
        defer step(i);
    }
}
f();
