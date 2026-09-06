fn choose(c: bool, a: int, b: int) -> int {
    if c {
        return a;
    }
    return b;
}

fn count_to(n: int) -> int {
    let i = 0;
    while i < n {
        i = i + 1;
    }
    return i;
}

struct Box {
    v: int,
}

fn add1(p: &mut int) {
    *p = *p + 1;
}

println(choose(true, 1, 2));
println(count_to(3));

let x = 10;
let r: &mut int = &mut x;
add1(r);
println(x);

let b = Box { v: 4 };
b.v = 5;
println(b.v);

for i in 0..2 {
    println(i);
}
