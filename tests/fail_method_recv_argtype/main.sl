struct P { x: int }
impl P {
    fn sum(self: P, a: int) -> int { return self.x + a; }
}
fn make() -> P { return P { x: 1 }; }
println(make().sum("one"));
