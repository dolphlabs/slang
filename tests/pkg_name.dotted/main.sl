// A package's name comes from its directory, and a directory name need
// not be an identifier. This test's own directory contains a '.', and it
// imports one that does ("lib.v2") and one that starts with a digit
// ("9lib"). Canonical type names are "<pkg>.<Name>", so a dotted package
// name used verbatim once generated invalid C for every struct in it.
import "lib.v2" as lib;
import "9lib" as nine;

pub struct Point {
    x: int,
    y: int,
}

impl Point {
    fn sum(self: Point) -> int {
        return self.x + self.y;
    }
}

struct Pair[T] {
    a: T,
    b: T,
}

let ps: [Point] = [];
push(ps, Point { x: 1, y: 2 });
push(ps, Point { x: 3, y: 4 });
println(to_str(ps[0].sum() + ps[1].sum()));

let p = Pair[str] { a: "left", b: "right" };
println(p.a + " " + p.b);

let b = lib.make(21);
println(to_str(b.twice()));
let w = lib.wrap(7);
println(to_str(w.v));

let n = nine.make(1);
println(to_str(n.v));
