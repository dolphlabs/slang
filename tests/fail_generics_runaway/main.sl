// an instance that needs a new instance forever.
struct Bad[T] { x: opt[Bad[[T]]] }
fn f(b: Bad[int]) {}
