// type parameters on an impl of a struct that has none.
struct Point { x: int }

impl Point[T] {
    fn get(self: Point) -> int { return self.x; }
}
