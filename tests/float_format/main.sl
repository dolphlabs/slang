// Floats print as the shortest text that reads back as the same number,
// everywhere a float becomes text: println, to_str, inspect, json.encode.
// They used %g -- six significant digits -- so 500002000000.0 printed as
// 5.00002e+11 and a float sent through json.encode came back changed. An
// f32 is as short as an f32 needs; json writes NaN and inf as null.
import "json";
import "math";
struct P { a: float, b: f32 }
println(500002000000.0);
println(0.1 + 0.2);
println(1.0);
println(-0.0);
println(3.141592653589793);
println(1000000000000000000000.0);
println(0.0000001);
println(123456789.125);
let z = 0.0;
println(1.0 / z);
println(z / z);
let f: f32 = 0.1;
println(f);
println(to_str(f));
println(to_str(0.000000000000000000000000000000000000000000001234));
println(inspect(P { a: 0.1 + 0.2, b: f }));
println(json.encode(P { a: 1.0 / z, b: f }));
println(json.encode(P { a: 0.30000000000000004, b: 16777216.0 }));
let x = 0.1 + 0.2;
let back = to_float(to_str(x)) ?? 0.0;
println(back == x);
// Shortest where a search through %.15g..%.17g was not: a power of two
// (an asymmetric rounding interval) and subnormals. Python's repr agrees.
println(math.float_from_bits(27021597764222976));   // 2^-1017
println(math.float_from_bits(10489504892952));      // a subnormal
println(math.float_from_bits(1));                    // the smallest subnormal
let f2: f32 = 16777217.0;                            // not an f32: rounds to 2^24
println(f2);
