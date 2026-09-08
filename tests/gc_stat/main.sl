let xs: [str] = [];
let i = 0;
while i < 1000 {
    push(xs, to_str(i));
    i = i + 1;
}
println(len(xs));