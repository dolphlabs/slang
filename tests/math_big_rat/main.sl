import "math/big";
import "math";
let r = big.rat_parse("0.125") ?? big.rat_zero();
println(r.format());
let third = big.rat(big.from_int(1), big.from_int(3)) ?? big.rat_zero();
println(third.add(third).add(third).format());
println(third.format_decimal(10));
println((big.rat_parse("-7/14") ?? big.rat_zero()).format());
println((big.rat_parse("2.5e-3") ?? big.rat_zero()).format());
println((big.rat_parse("-12.75") ?? big.rat_zero()).floor().format(10));
println((big.rat_parse("-12.75") ?? big.rat_zero()).ceil().format(10));
println((big.rat_parse("5/2") ?? big.rat_zero()).round().format(10));
println((big.rat_parse("7/2") ?? big.rat_zero()).round().format(10));
println(third.float_of());
println((big.rat_parse("1e400") ?? big.rat_zero()).float_of());
let bad = big.rat_parse("1/0");
if let x = bad { println("no!"); } else let e = err_of(bad) { println(e); }
let bad2 = big.rat_parse("1.");
if let x = bad2 { println("no!"); } else let e = err_of(bad2) { println(e); }
println(third.cmp(big.rat_from_int(0)));
println((third.div(big.rat_zero()) ?? big.rat_from_int(-1)).format());
let x = big.from_bytes_be(b"\x01\x00\x00\x00\x00\x00\x00\x00\x01");
println(x.format(16));
println(len(x.bytes_be()));
println(big.from_int(2).pow(200).float_of() == math.pow(2.0, 200.0));
println(big.from_int(-9223372036854775807 - 1).format(10));
println((big.parse("0xff_ff", 16) ?? big.zero()).format(10));
