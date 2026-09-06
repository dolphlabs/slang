fn first<'a, 'b>(x: &'a int, y: &'b int) -> &'a int {
    return x;
}

struct Holder<'a> {
    r: &'a int,
}

let a = 1;
let b = 2;
let r = first(&a, &b);
b = 9;
println(*r);
println(b);

let n = 7;
let h = Holder { r: &n };
println(*h.r);
