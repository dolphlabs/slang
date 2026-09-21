// Box[int,str] names two arguments for a one-parameter struct.
struct Box[T] { v: T }
let b: Box[int, str] = Box[int] { v: 1 };
