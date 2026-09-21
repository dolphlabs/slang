// An `own` value passed as an argument to a method on a temporary
// receiver is consumed by the call: the callee frees its parameter, so the
// caller must not free the binding again. 200000 iterations would abort
// with a double free if the argument's drop flag were left set.
struct Point {
    x: int,
    y: int,
}

impl Point {
    fn with(self: Point, other: own Point) -> int {
        return self.x + other.x;
    }
}

fn mk() -> Point {
    return Point { x: 1, y: 2 };
}

fn give() -> own Point {
    return Point { x: 5, y: 6 };
}

let total = 0;
let i = 0;
while i < 200000 {
    let a: own Point = Point { x: 3, y: 4 };
    total = total + mk().with(a);
    i = i + 1;
}
println(total);

// an `own` temporary as the receiver itself
println(give().with(give()));
