// A method call reads its receiver after evaluating its arguments, so the
// receiver must stay rooted across every safepoint inside them. When the
// call was the receiver's last use, liveness left it out of the roots of
// a nested call in the arguments: a collection there freed it, and the
// method ran on reused memory (a null dereference). churn() allocates
// past the 512 KB nursery, so a minor collection runs inside every
// argument, generic receiver and plain one alike.
import "strings";

gc struct Box[T] {
    items: [str],
    tag: str,
    state: T,
}

impl Box[T] {
    fn serve(self: Box[T], s: str, id: str) -> int {
        return len(self.items) + len(self.items[39]) + len(self.tag) + len(s) + len(id);
    }
}

gc struct Plain {
    items: [str],
}

impl Plain {
    fn count(self: Plain, s: str) -> int {
        return len(self.items) + len(self.items[39]) + len(s);
    }
}

fn names(n: int) -> [str] {
    let l: [str] = [];
    let i = 0;
    while i < n {
        push(l, "item-" + to_str(i));
        i = i + 1;
    }
    return l;
}

fn churn(s: str) -> str {
    let junk: [str] = [];
    let i = 0;
    while i < 64 {
        push(junk, s + strings.repeat("-", 10000));
        i = i + 1;
    }
    return strings.slice(junk[63], 0, 4);
}

let total = 0;
let k = 0;
while k < 300 {
    let b = Box[int] { items: names(40), tag: "box", state: k };
    let first = b.serve(churn("x"), "req-42");
    // b's last use: the receiver of a call whose argument collects
    let last = b.serve(churn("y"), "req-43");
    let p = Plain { items: names(40) };
    total = total + first + last + p.count(churn("z"));
    k = k + 1;
}
println(total);
