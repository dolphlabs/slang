// an impl block that declares a different number of type parameters than its struct.
struct Box[T] { v: T }

impl Box[T, U] {
    fn get(self: Box[T]) -> T { return self.v; }
}
