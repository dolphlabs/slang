// a type argument that is not a type.
struct Box[T] { v: T }
fn f(b: Box[Nope]) {}
