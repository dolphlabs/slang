// Every analysis pass must reach a generic method's body, not just the
// bodies a package declares. A pass that skips them does not fail to
// compile -- it silently fails to root a value (liveness), to drop or
// move one (move), or to check a borrow. Each block below needs one
// specific pass to have walked this instance body.

gc struct Holder[T] {
    items: [T],
    tag: str,
}

struct Counter {
    n: int,
}

fn churn() -> int {
    let s = "";
    let i = 0;
    while i < 400 {
        s = s + to_str(i);
        i = i + 1;
    }
    return len(s);
}

impl Holder[T] {
    // LIVENESS: `made` is a heap value whose only reference is this local,
    // held across an allocating call. Unrooted, the collector frees it and
    // the returned string is garbage.
    fn liveness(self: Holder[T], x: T) -> str {
        let made = self.tag + "-made";
        push(self.items, x);
        churn();
        return made + "/" + to_str(len(self.items));
    }

    // BORROW: a shared borrow of a local, read after a call. The borrow
    // checker has to see this body to have an opinion at all.
    fn borrows(self: Holder[T]) -> int {
        let c = Counter { n: 41 };
        let r = &c;
        churn();
        return r.n + 1;
    }

    // MIR/MOVE: an owned value moved into a call, then reinitialized and
    // used again. If the move pass never walks this body, the drop flags
    // are wrong and the value is freed twice or leaked.
    fn moves(self: Holder[T]) -> int {
        let a: own Counter = Counter { n: 1 };
        let b = a;              // move
        a = Counter { n: 2 };   // reinitialize
        return b.n + a.n;
    }

    // ESCAPE: the struct literal never leaves this body, so escape
    // analysis may keep it on the stack; its heap field must still be
    // rooted across the call below (the bug #174 fixed, inside an
    // instance this time).
    fn escapes(self: Holder[T]) -> int {
        let local = Holder[int] { items: [1, 2, 3], tag: "local" };
        churn();
        return len(local.items) + len(local.tag);
    }
}

let h = Holder[str] { items: [], tag: "h" };
println(h.liveness("a"));
println(h.borrows());
println(h.moves());
println(h.escapes());

let hi = Holder[int] { items: [9], tag: "i" };
println(hi.liveness(8));
println(hi.escapes());
