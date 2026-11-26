fn add(a: int, b: int) -> int {
    return a + b;
}
fn f() {
    defer add(1);
}
f();
