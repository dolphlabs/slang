pub struct Point {
    x: int,
    y: int,
}

impl Point {
    fn secret(self: Point) -> int {
        return self.x * self.y;
    }
}
