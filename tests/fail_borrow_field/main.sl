struct Point {
    x: int,
    y: int,
}

let p = Point { x: 1, y: 2 };
let rx: &int = &p.x;
let rp: &mut Point = &mut p;
println(*rx);
println(rp.x);
