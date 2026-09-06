fn bad(x: &'a int) -> &'a int {
    return x;
}

let n = 1;
println(*bad(&n));
