import "strings";

// Float literals used to be emitted into the C with "%g", six
// significant digits, so each of these compiled to a different number.
fn check(name: str, got: float, want: str) {
    let s = strings.from_float(got);
    if s != want {
        println("FAIL " + name + ": " + s + " != " + want);
        exit(1);
    }
}

let pi = 3.141592653589793;
check("pi", pi, "3.141592653589793");
check("frac", 123456789.125, "123456789.125");
check("tiny", 0.000001234567891, "1.234567891e-06");
check("sum", 0.1 + 0.2, "0.30000000000000004");
check("whole", 1.0, "1");
check("negzero", -0.0, "-0");
if 123456789.125 != 123456789.0 + 0.125 {
    println("FAIL literal differs from its computed value");
    exit(1);
}

// strings.from_float round-trips through to_float
let x = 2.0 / 3.0;
let back = to_float(strings.from_float(x));
guard let y = back else {
    println("FAIL to_float");
    exit(1);
}
if y != x {
    println("FAIL round trip");
    exit(1);
}
println("PASS");
