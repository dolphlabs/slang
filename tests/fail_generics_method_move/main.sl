// Use-after-move inside a generic method's body must be rejected. The
// move pass only sees this body if it walks generic instances, and a
// body it skips is checked by nothing.
struct Rec {
    n: int,
}

struct Box[T] {
    v: T,
}

impl Box[T] {
    fn bad(self: Box[T]) -> int {
        let a: own Rec = Rec { n: 1 };
        let b = a;          // moves
        return a.n + b.n;   // a is gone
    }
}

let b = Box { v: 1 };
println(b.bad());
