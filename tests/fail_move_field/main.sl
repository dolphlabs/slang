struct Point {
    x: int,
    y: int,
}

struct Wrap {
    p: own Point,
}

let w = Wrap { p: Point { x: 1, y: 2 } };
let q = w.p;
