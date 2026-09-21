struct P { x: int }
impl P {
    fn double(self: P) -> int { return self.x * 2; }
}
fn make() -> P { return P { x: 1 }; }
println(make().double(1));
