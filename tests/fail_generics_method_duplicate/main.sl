// one method declared twice in a generic impl block.
struct Box[T] { v: T }

impl Box[T] {
    fn a(self: Box[T]) -> T { return self.v; }
    fn a(self: Box[T]) -> T { return self.v; }
}
