// Float literals with an exponent (1e9, 6.02e23, 1.5E-7, 2e+3), which an
// exponent alone makes a float, and digit separators in a float. Before,
// `1e9` did not parse, and `1_000.5` was 1.0: the value was read from the
// source text, and strtod stopped at the first '_'.
let a = 1e9;
let b = 6.02e23;
let c = 1.5E-7;
let d = 2e+3;
let e = 1_000.5;
let f = 1_000_000e-3;
let g = 0.000_001;
let tiny = 4.9e-324;              // the smallest subnormal: not 0
println(a);
println(b);
println(c);
println(d);
println(e);
println(f);
println(g);
println(tiny > 0.0);
println(a / 1000.0);
println(1e3 + 1);                  // a float: 1001
let n = 3;                         // an int: no exponent, no point
println(n + 1);
for i in 0..3 { print(i); }        // `0..3` is still a range
println("");
