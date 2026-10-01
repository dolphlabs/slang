// Arithmetic on two integer literals is int (64-bit) arithmetic. C types
// a literal that fits in 32 bits as `int`, so these used to be computed
// in 32 bits and wrap (60 * 1000000000 printed -129542144).
let minute_ns = 60 * 1000000000;
println(to_str(minute_ns));
println(to_str(3 * 1000000000));
println(to_str(60 * 1000 * 1000 * 1000));
println(to_str(-3 * 1000000000));
println(to_str(2000000000 + 2000000000));
println(to_str(0 - 2000000000 - 2000000000));
println(to_str(1 << 40));
println(to_str(24 * 3600 * 1000000000));
let n = 60;
println(to_str(n * 1000000000));
println(to_str(minute_ns / 1000000000));
