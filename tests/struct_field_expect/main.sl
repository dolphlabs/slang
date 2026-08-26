// Struct literal field values are inferred with the target field's
// type pushed as the expected type, the same way function-call
// arguments already are -- so 'none'/'some(..)'/'ok(..)'/'err(..)'
// can appear directly as a field value without a redundant
// annotation on some intermediate variable.
struct Wrapper {
    maybe: opt[int],
    outcome: result[int, str],
}

let w1 = Wrapper{ maybe: none, outcome: ok(5) };
guard let m1 = w1.maybe else {
    println("w1.maybe correctly none");
}
guard let v1 = w1.outcome else {
    println("BUG: w1.outcome should be ok");
    exit(1);
}
println(to_str(v1));

let w2 = Wrapper{ maybe: some(9), outcome: err("boom") };
guard let m2 = w2.maybe else {
    println("BUG: w2.maybe should be some");
    exit(1);
}
println(to_str(m2));
guard let v2 = w2.outcome else {
    println("w2.outcome correctly err");
    exit(0);
}
println("BUG: w2.outcome should be err");
