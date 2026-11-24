struct Box[T] { v: T }
let b: Box[,] = Box[int] { v: 1 };
println(to_str(b.v));
