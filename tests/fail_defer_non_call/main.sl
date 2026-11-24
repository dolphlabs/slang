fn f() {
    let x = 1;
    defer x + 1;
}
f();
