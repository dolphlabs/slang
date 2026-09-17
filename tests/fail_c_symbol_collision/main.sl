// A function whose name spells a method's C symbol is refused by name,
// not left to fail as a duplicate definition in the generated C.
gc struct Point { x: int }
impl Point {
    fn x(self: Point) -> int { return self.x; }
}
fn Point__m_x(p: Point) -> int { return 0; }
let p = Point { x: 1 };
println(p.x());
