struct Point {
    x: int,
    y: int,
}

fn take(p: own Point) -> int {
    return p.x;
}

let a: own Point = Point { x: 1, y: 2 };
println(take(a));
println(a.x);
