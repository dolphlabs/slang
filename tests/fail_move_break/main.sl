// A break carries its moves to the code after the loop.
struct P { x: int }
fn take(p: own P) -> int { return p.x; }
fn f(n: int) -> int {
    let c: own P = P { x: 1 };
    for i in 0..n {
        if i == 2 {
            take(c);
            break;
        }
    }
    return take(c);
}
println(f(3));
