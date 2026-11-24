struct H {
    v: int,
}
fn take(h: own H) {
    let _ = h.v;
}
fn f() {
    let h: own H = H { v: 1 };
    defer take(h);
    take(h);
}
f();
