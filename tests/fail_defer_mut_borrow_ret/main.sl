fn bump(x: &mut int) {
    *x += 1;
}
fn f() -> int {
    let x = 1;
    defer bump(&mut x);
    return x;
}
println(f());
