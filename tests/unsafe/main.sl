let x = 10;
let p: *mut int = &mut x;
unsafe {
    *p = 5;
    println(*p);
    let q = p + 1;
    let r = q - 1;
    println(*r);
    let s = 0 + r;
    println(*s);
}
println(x);

let y: i32 = 1;
let pp: ptr[i32] = &mut y;
unsafe {
    *pp = 42;
    println(*pp);
}

let z = 3;
let rp: *int = &z;
unsafe {
    println(*rp);
}

fn bump(dst: *mut int) {
    unsafe {
        *dst = *dst + 1;
    }
}

let n = 7;
bump(&mut n);
println(n);
