// an instance that contains itself by value.
struct S[T] { x: S[T] }
fn f(s: S[int]) {}
