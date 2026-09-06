struct Point {
    x: int,
    y: int,
}

fn take(p: own Point) -> int {
    return p.x;
}

fn give() -> own Point {
    return Point { x: 1, y: 2 };
}

let a: own Point = Point { x: 3, y: 4 };
println(take(a));

let b = give();
b.x = 9;
println(b.x);

let c: own Point = Point { x: 5, y: 6 };
c = Point { x: 7, y: 8 };
println(c.x);

let d = 10;
let e = d;
println(d);
println(e);

let p: own Point = Point { x: 0, y: 0 };
for i in 0..3 {
    let q = p;
    p = Point { x: i, y: i };
}
println(p.x);
