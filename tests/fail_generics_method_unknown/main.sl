// a method the template does not declare.
struct Box[T] { v: T }

impl Box[T] {
    fn get(self: Box[T]) -> T { return self.v; }
}

let b = Box { v: 1 };
println(b.nope());
