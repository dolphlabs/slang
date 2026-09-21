// lifetime parameters on a method of a generic struct.
struct Box[T] { v: T }

impl Box[T] {
    fn get<'a>(self: Box[T]) -> T { return self.v; }
}

let b = Box { v: 1 };
println(b.get());
