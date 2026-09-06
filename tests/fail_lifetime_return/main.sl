fn bad<'a, 'b>(x: &'a int, y: &'b int) -> &'a int {
    return y;
}

let a = 1;
let b = 2;
println(*bad(&a, &b));
