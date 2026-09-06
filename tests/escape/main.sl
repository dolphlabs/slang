struct Point {
    x: int,
    y: int,
}

impl Point {
    fn sum(self: Point) -> int {
        return self.x + self.y;
    }
}

fn heap_it(p: own Point) -> own Point {
    p.x = p.x + 1;
    return p;
}

fn local_only() -> int {
    let p: own Point = Point { x: 1, y: 2 };
    return p.x + p.sum();
}

fn local_gc() -> int {
    let p: gc Point = Point { x: 4, y: 5 };
    return p.sum();
}

println(local_only());
println(local_gc());

let q: own Point = Point { x: 10, y: 20 };
let r = heap_it(q);
println(r.x);
println(r.y);
