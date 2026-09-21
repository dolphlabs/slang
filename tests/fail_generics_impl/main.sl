// methods on a generic struct are not part of this step.
struct Box[T] { v: T }
impl Box[T] {
    fn get(self: Box[T]) -> T { return self.v; }
}
