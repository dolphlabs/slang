struct Point {
    x: int,
    y: int,
}

impl Point {
    fn sum(self: Point) -> int {
        return self.x + self.y;
    }
}

let p: own Point = Point { x: 3, y: 4 };
println(p.x);
p.x = 10;
println(p.sum());

let n: own i32 = 5;
*n = 11;
println(*n);
