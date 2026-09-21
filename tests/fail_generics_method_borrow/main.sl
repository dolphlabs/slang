// A borrow error inside a generic method's body must be rejected. The
// borrow checker works off MIR, which is built by walking function
// bodies -- including every generic instance.
struct Rec {
    n: int,
}

struct Box[T] {
    v: T,
}

impl Box[T] {
    fn bad(self: Box[T]) -> int {
        let c = Rec { n: 1 };
        let r = &c;
        c.n = 2;            // mutated while borrowed
        return r.n;
    }
}

let b = Box { v: 1 };
println(b.bad());
