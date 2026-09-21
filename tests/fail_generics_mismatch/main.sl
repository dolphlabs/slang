// two instances of one template are different types.
struct Box[T] { v: T }
let b: Box[int] = Box[str] { v: "x" };
