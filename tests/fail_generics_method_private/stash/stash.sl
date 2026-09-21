pub struct Slot[T] { v: T }

impl Slot[T] {
    fn raw(self: Slot[T]) -> T { return self.v; }
}
