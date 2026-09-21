// a method body that does not type-check for the T it is asked for; the error names the instance and the line that asked.
struct Box[T] { v: T }

impl Box[T] {
    fn doubled(self: Box[T]) -> int { return self.v * 2; }
}

let b = Box { v: "text" };
println(b.doubled());
