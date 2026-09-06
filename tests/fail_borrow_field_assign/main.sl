struct Point {
    x: int,
    y: int,
}

let p = Point { x: 1, y: 2 };
let rx: &int = &p.x;
p.x = 3;
println(*rx);
