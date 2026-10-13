// Integer arithmetic wraps two's-complement, so dividing a signed type's
// minimum by -1 is defined: the quotient wraps back to the minimum and the
// remainder is 0, for every signed width and every spelling of the
// division. The operands are parsed at run time so the C compiler cannot
// fold them. A zero divisor still panics.

fn parsed(s: str) -> int {
    return to_int(s) ?? 0;
}

fn safe_div(a: int, b: int) -> int {
    return a / b;
}

let min = parsed("-9223372036854775808");
let neg1 = parsed("-1");

println(min / neg1);
println(min % neg1);
let q = min;
q /= neg1;
println(q);
let r = min;
r %= neg1;
println(r);
println(min / -1);
println(min % -1);
println(safe_div(min, neg1));

let m32 = parsed("-2147483648") as i32;
let n32 = neg1 as i32;
println(m32 / n32);
println(m32 % n32);

let m16 = parsed("-32768") as i16;
println(m16 / (neg1 as i16));

let d: duration = min as duration;
println(d / (neg1 as duration));

// ordinary results are unchanged
println(parsed("7") / neg1);
println(parsed("-7") / parsed("2"));
println(parsed("-7") % parsed("2"));
println(parsed("9223372036854775807") / neg1);

// a zero divisor is still a panic, caught like any other
let h = spawn safe_div(1, parsed("0"));
let jr = join_wait(h);
if let _v = jr {
    println("no panic");
} else {
    println("division by zero panics");
}
