// The receiver of a method call is a value nobody has bound to a name yet:
// `mk(20).total(mk(30))` allocates the receiver, THEN allocates the
// argument, and a collection during the second can only spare the first if
// the receiver was rooted. tests/run_tests.sh runs this under
// SLANG_GC_THRESHOLD_KB=16, where a collection happens every few
// allocations, so an unrooted receiver shows up as garbage in the sums.

gc struct Box {
    items: [int],
    name: str,
}

fn mk(n: int) -> Box {
    let xs: [int] = [];
    let i = 0;
    while i < n {
        push(xs, i);
        i = i + 1;
    }
    return Box { items: xs, name: "box" + to_str(n) };
}

impl Box {
    fn total(self: Box, other: Box) -> int {
        let t = 0;
        for x in self.items {
            t = t + x;
        }
        for y in other.items {
            t = t + y;
        }
        return t + len(self.name) + len(other.name);
    }

    fn same(self: Box, other: Box) -> Box {
        // allocates as well, so a chain has a fresh receiver at every link
        return mk(len(self.items) + len(other.items));
    }

    fn size(self: Box) -> int {
        return len(self.items);
    }
}

let sum = 0;
let i = 0;
while i < 3000 {
    // receiver allocates, argument allocates, and the result is a new box
    // that becomes the next receiver
    sum = sum + mk(20).total(mk(30));
    sum = sum + mk(5).same(mk(6)).same(mk(7)).size();
    i = i + 1;
}
// per iteration: total(20,30) = 190 + 435 + 5 + 5 = 635;
// same(5,6) -> 11 items, same(11,7) -> 18 items => size 18
println(sum);
