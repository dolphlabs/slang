// spawn does not support methods (with an implicit self) in v1
struct Point { x: int }
impl Point {
    fn show(self: Point) { println(self.x); }
}
let p = Point { x: 1 };
spawn p.show();
