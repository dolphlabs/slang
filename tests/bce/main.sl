fn add1(p: &mut int) {
    *p = *p + 1;
}

let xs = [1, 2, 3, 4, 5];
let total = 0;
for x in xs {
    total = total + x;
}
println(total);

let acc = 0;
for row in [[10, 20], [30, 40]] {
    for n in row {
        acc = acc + n;
    }
}
println(acc);

let n = 40;
add1(&mut n);
add1(&mut n);
println(n);

let wsrc = arena_new(16);
let w = wsrc.wire(4);
w[0] = 1;
w[1] = 2;
w[2] = 3;
w[3] = 4;
let wsum = 0;
for i in 0..len(w) {
    wsum = wsum + w[i];
}
println(wsum);
