let x = 1;
let r: &int = &x;
x = 2;
println(*r);
