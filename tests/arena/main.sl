struct Pair {
    x: int,
    y: int,
}

fn bump(a: &mut arena) -> &mut int {
    return a.alloc(1);
}

let a = arena_new(256);
let p: &mut int = a.alloc(7);
*p = *p + 2;
println(*p);

let q = a.alloc(Pair { x: 3, y: 4 });
println(q.x);
println(q.y);

let r = bump(&mut a);
*r = 11;
println(*r);

let b: &mut u8 = a.alloc_bytes(4);
*b = 65;
println(*b);

a.reset();
let s = a.alloc(99);
println(*s);
