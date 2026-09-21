// one parameter, two different types in one literal.
struct Two[T] { a: T, b: T }
let t = Two { a: 1, b: "x" };
