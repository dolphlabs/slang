// A generic instance sees only ITS OWN parameters. B[int] is built from
// inside A[str], where T is in scope, but B's declaration has no T.
struct A[T] { b: B[int] }
struct B[U] { y: T }
fn f(a: A[str]) {}
