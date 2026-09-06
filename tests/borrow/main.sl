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
