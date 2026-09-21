// `a` is moved into the method's `own` parameter, so it cannot be used
// afterwards -- the same rule as for a plain function call.
struct Point { x: int, y: int }
impl Point {
    fn with(self: Point, other: own Point) -> int { return self.x + other.x; }
}
fn mk() -> Point { return Point { x: 1, y: 2 }; }
let a: own Point = Point { x: 3, y: 4 };
println(mk().with(a));
println(a.x);
