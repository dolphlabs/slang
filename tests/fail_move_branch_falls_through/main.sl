// Only the branch that returns is left out of the join: the one that
// falls through still moved the value.
struct P { x: int }
fn take(p: own P) -> int { return p.x; }
fn f(b: bool) -> int {
    let c: own P = P { x: 1 };
    if b {
        take(c);
    } else {
        take(c);
        return 0;
    }
    return take(c);
}
println(f(true));
