// a parameter no field mentions cannot be inferred from a literal.
struct Tag[T] { n: int }
let t = Tag { n: 1 };
