struct Point {
    x: int,
    y: int,
}

fn id(p: &int) -> &int {
    return p;
}

fn add1(p: &mut int) {
    *p = *p + 1;
}

fn pick(c: bool) -> int {
    let x = 1;
    let y = 2;
    let r: &int = &x;
    let s: &int = &y;
    if c {
        return *r;
    }
    return *s;
}

println(pick(true));

let n = 7;
let a: &int = &n;
let b: &int = &n;
println(*a);
println(*b);

let m = 3;
let rm: &mut int = &mut m;
*rm = 9;
println(*rm);
println(m);

let z = 10;
add1(&mut z);
println(z);

let q = 4;
let rq = id(&q);
println(*rq);
q = 5;
println(q);

let w = 1;
let r = &w;
println(*r);
w = 2;
println(w);

let p = Point { x: 1, y: 2 };
let rx: &int = &p.x;
let ry: &int = &p.y;
println(*rx);
println(*ry);

let u = Point { x: 3, y: 4 };
let mx: &mut int = &mut u.x;
let my: &int = &u.y;
*mx = 30;
println(*mx);
println(*my);

let s = Point { x: 5, y: 6 };
let sx = &s.x;
s.y = 9;
println(*sx);
println(s.y);
