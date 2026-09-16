pub struct Point {
    x: int,
    y: int,
}

impl Point {
    // exported: callable from any package
    pub fn sum(self: Point) -> int {
        return self.x + self.y;
    }

    pub fn moved(self: Point, dx: int, dy: int) -> Point {
        return Point { x: self.x + dx, y: self.y + dy };
    }

    // not exported: only this package may call it
    fn secret(self: Point) -> int {
        return self.x * self.y;
    }

    // ...which a pub method is free to do on the caller's behalf
    pub fn area(self: Point) -> int {
        return self.secret();
    }
}
