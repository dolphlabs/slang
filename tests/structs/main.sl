struct Point {
    x: int,
    y: int,
}

impl Point {
    fn sum(self: Point) -> int {
        return self.x + self.y;
    }

    fn moved(self: Point, dx: int, dy: int) -> Point {
        return Point { x: self.x + dx, y: self.y + dy };
    }
}

struct Rect {
    tl: Point,
    br: Point,
}

impl Rect {
    fn area(self: Rect) -> int {
        let w = self.br.x - self.tl.x;
        let h = self.br.y - self.tl.y;
        return w * h;
    }
}

let p = Point { x: 3, y: 4 };
println(p.sum());
p.x = 10;
println(p.sum());

let q = p.moved(1, 2);
println(q.x);
println(q.y);

let r = Rect { tl: Point { x: 0, y: 0 }, br: Point { x: 4, y: 5 } };
println(r.area());
println(r.tl.y);
r.br.x = 6;
println(r.area());
println(r.br.x);

let pts: [Point] = [p, q];
push(pts, r.tl);
println(len(pts));
println(pts[2].x);