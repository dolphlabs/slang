struct Point {
    x: int,
    y: int,
}

impl Point {
    fn sum(self: Point) -> int {
        return self.x + self.y;
    }
}

let n: int = 7;
let r: &int = &n;
println(*r);

let m: int = 3;
let rm: &mut int = &mut m;
*rm = 9;
println(*rm);
println(m);

let p = Point { x: 1, y: 2 };
let rp: &Point = &p;
println(rp.x);
println(rp.sum());

let q = Point { x: 4, y: 5 };
let rqm: &mut Point = &mut q;
rqm.x = 10;
println(rqm.sum());
println(q.x);

let boxed: gc Point = Point { x: 6, y: 7 };
println(boxed.x);
boxed.y = 8;
println(boxed.sum());
