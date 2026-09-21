// two impl blocks for one generic struct.
struct Box[T] { v: T }

impl Box[T] {
    fn a(self: Box[T]) -> T { return self.v; }
}

impl Box[T] {
    fn b(self: Box[T]) -> T { return self.v; }
}
