fn d(s: str) -> Decimal {
    let r = parse(s);
    guard let v = r else let e = err_of(r) {
        panic("parse " + s + ": " + e);
    }
    return v;
}

fn show(o: opt[Decimal]) -> str {
    if let v = o {
        return format(v);
    }
    return "none";
}

fn mode_of(name: str) -> Rounding {
    let r: result[Rounding, str] = Rounding.from_str(name);
    guard let m = r else {
        panic("no rounding mode " + name);
    }
    return m;
}

fn parse_err(s: str) -> str {
    let r = parse(s);
    if let v = r {
        panic("expected an error for '" + s + "', got " + format(v));
    }
    return err_of(r);
}

// ---- against exact rational arithmetic -------------------------------------

fn test_should_match_the_reference_on_every_vector() {
    let bad = 0;
    for c in vec_cases() {
        let op = c[0];
        let a = d(c[1]);
        let want = c[5];
        let got = "";
        if op == "add" {
            got = show(add(a, d(c[2])));
        } else if op == "sub" {
            got = show(sub(a, d(c[2])));
        } else if op == "mul" {
            got = show(mul(a, d(c[2])));
        } else if op == "mul_round" {
            got = show(mul_round(a, d(c[2]), to_int(c[3]) ?? -1, mode_of(c[4])));
        } else if op == "div" {
            let r = div(a, d(c[2]), to_int(c[3]) ?? -1, mode_of(c[4]));
            got = "none";
            if let v = r {
                got = format(v);
            }
        } else if op == "round" {
            got = show(round(a, to_int(c[3]) ?? -1, mode_of(c[4])));
        } else if op == "cmp" {
            got = "" + cmp(a, d(c[2]));
        }
        if got != want {
            bad += 1;
            if bad <= 10 {
                println("  " + op + "(" + c[1] + ", " + c[2] + ", " + c[3] + ", "
                        + c[4] + "): got " + got + ", want " + want);
            }
        }
    }
    assert(bad == 0, to_str(bad) + " of " + to_str(len(vec_cases())) + " vectors differ");
}

// ---- parsing and formatting ------------------------------------------------

fn test_should_keep_the_scale_written() {
    assert(format(d("1.50")) == "1.50", "1.50");
    assert(format(d("-0.005")) == "-0.005", "-0.005");
    assert(format(d("42")) == "42", "42");
    assert(format(d("+7.0")) == "7.0", "+7.0");
    assert(format(d("007.25")) == "7.25", "leading zeros");
    assert(format(d("0")) == "0", "0");
    assert(format(d("-0")) == "0", "negative zero is zero");
    assert(format(d("-0.00")) == "0.00", "negative zero keeps its scale");
    assert(scale_of(d("1.50")) == 2, "scale of 1.50");
}

fn test_should_apply_exponents() {
    assert(format(d("1.5e3")) == "1500", "1.5e3");
    assert(format(d("2E-4")) == "0.0002", "2E-4");
    assert(format(d("1.25e+1")) == "12.5", "1.25e+1");
    assert(format(d("-3e0")) == "-3", "-3e0");
    assert(format(d("1e37")) == "10000000000000000000000000000000000000", "1e37");
}

fn test_should_hold_38_digits_and_no_more() {
    let max = "99999999999999999999999999999999999999";
    assert(format(d(max)) == max, "38 nines");
    assert(format(d("-" + max)) == "-" + max, "negative 38 nines");
    assert(format(d("0.00000000000000000000000000000000000001")) ==
           "0.00000000000000000000000000000000000001", "scale 38");
    let e = parse_err("999999999999999999999999999999999999999");
    assert(strings_has(e, "more than 38 significant digits"), e);
    e = parse_err("1e38");
    assert(strings_has(e, "more than 38 digits"), e);
    e = parse_err("0.000000000000000000000000000000000000001");
    assert(strings_has(e, "more than 38 digits after the point"), e);
    // Zeros past 38 significant digits still need room: 41 digits.
    e = parse_err("12345678901234567890123456789012345678000");
    assert(strings_has(e, "needs more than 38 digits"), e);
    // Past 38 significant digits, zeros in the fraction are exact.
    assert(format(d("1234567890123456789012345678901234567.8000")) ==
           "1234567890123456789012345678901234567.8", "trailing fraction zeros");
    assert(format(d("1.0000000000000000000000000000000000000000")) ==
           "1.0000000000000000000000000000000000000", "zeros past scale 38");
}

fn test_should_reject_what_is_not_a_number() {
    let cases = ["", "-", "+", ".5", "5.", "1.2.3", "1,000", " 1", "1 ",
                 "0x10", "1e", "1e+", "NaN", "Infinity", "--1", "1_000", "١"];
    for s in cases {
        let r = parse(s);
        if let v = r {
            panic("'" + s + "' parsed as " + format(v));
        }
    }
    assert(strings_has(parse_err(".5"), "digit before the point"), ".5");
    assert(strings_has(parse_err("5."), "digit after the point"), "5.");
    assert(strings_has(parse_err(""), "empty"), "empty");
    assert(strings_has(parse_err("12x"), "unexpected 'x' at 2"), "12x");
}

fn test_should_parse_inside_a_buffer() {
    let b = b"amount=19.99;";
    let r = parse_bytes(b, 7, 12);
    guard let v = r else let e = err_of(r) { panic(e); }
    assert(format(v) == "19.99", "parse_bytes");
    let bad = parse_bytes(b, 7, 99);
    assert(!is_ok(bad), "range past the end");
}

// ---- conversions -----------------------------------------------------------

fn test_should_convert_to_and_from_int_units() {
    assert(format(from_int(-42)) == "-42", "from_int");
    assert(format(from_units(1999, 2) ?? zero()) == "19.99", "from_units");
    assert(format(from_units(-5, 3) ?? zero()) == "-0.005", "negative units");
    let min = from_units(-9223372036854775807 - 1, 0) ?? zero();
    assert(format(min) == "-9223372036854775808", "the smallest int");
    assert(format(from_int(9223372036854775807)) == "9223372036854775807", "the largest int");
    assert(!is_some(from_units(1, 39)), "scale 39");
    assert(!is_some(from_units(1, -1)), "scale -1");
    assert((to_units(d("19.999"), 2, Rounding.HalfUp) ?? 0) == 2000, "to_units HalfUp");
    assert((to_units(d("19.999"), 2, Rounding.Down) ?? 0) == 1999, "to_units Down");
    assert((to_units(d("-0.125"), 2, Rounding.HalfEven) ?? 0) == -12, "to_units HalfEven");
    assert((to_units(d("9223372036854775807"), 0, Rounding.Down) ?? 0) == 9223372036854775807,
           "largest int back");
    assert((to_units(d("-9223372036854775808"), 0, Rounding.Down) ?? 0) == -9223372036854775807 - 1,
           "smallest int back");
    assert(!int_some(to_units(d("9223372036854775808"), 0, Rounding.Down)), "one past");
    assert(!int_some(to_units(d("-9223372036854775809"), 0, Rounding.Down)), "one below");
    assert(!int_some(to_units(d("1"), 39, Rounding.Down)), "bad scale");
    assert((int_of(d("-2.5"), Rounding.HalfEven) ?? 9) == -2, "int_of");
}

fn test_should_convert_floats_through_their_shortest_text() {
    assert(format(from_float(0.1, 2, Rounding.HalfEven) ?? zero()) == "0.10", "0.1");
    assert(format(from_float(2.675, 2, Rounding.HalfUp) ?? zero()) == "2.68",
           "2.675 is 2.675 as written, not 2.67499999...");
    assert(format(from_float(-1e-7, 8, Rounding.HalfEven) ?? zero()) == "-0.00000010", "tiny");
    let z = 0.0;
    assert(!is_some(from_float(z / z, 2, Rounding.HalfEven)), "NaN");
    assert(!is_some(from_float(1.0 / z, 2, Rounding.HalfEven)), "infinity");
    assert(!is_some(from_float(1e300, 0, Rounding.HalfEven)), "too large");
    assert(float_of(d("19.99")) == 19.99, "float_of");
}

// ---- arithmetic edges ------------------------------------------------------

fn test_should_overflow_to_none_not_wrap() {
    let max = d("99999999999999999999999999999999999999");
    assert(!is_some(add(max, d("1"))), "max + 1");
    assert(!is_some(sub(neg(max), d("1"))), "-max - 1");
    assert(show(add(max, d("-1"))) == "99999999999999999999999999999999999998", "max - 1");
    assert(!is_some(mul(max, d("2"))), "max * 2");
    assert(!is_some(round(max, 1, Rounding.HalfEven)), "max with one more digit");
    // Rounding to fewer places never overflows: the carry adds back at
    // most one of the digits it removed.
    assert(show(round(d("99999999999999999999999999999999999.999"), 2, Rounding.Up))
           == "100000000000000000000000000000000000.00", "carry into a new digit");
    let r = div(max, d("0.1"), 0, Rounding.HalfEven);
    assert(!is_ok(r), "max / 0.1");
}

fn test_should_refuse_division_by_zero_and_bad_scales() {
    let r = div(d("1"), d("0.000"), 2, Rounding.HalfEven);
    assert(strings_has(err_of(r), "division by zero"), err_of(r));
    let r2 = div(d("1"), d("3"), 39, Rounding.HalfEven);
    assert(strings_has(err_of(r2), "outside 0 to 38"), err_of(r2));
    assert(!is_some(mul_round(d("1"), d("1"), -1, Rounding.HalfEven)), "mul_round scale");
    assert(!is_some(round(d("1"), 39, Rounding.HalfEven)), "round scale");
}

fn test_should_divide_by_long_divisors() {
    // divisors of one, two and four limbs, through Knuth's algorithm D
    let r = div(d("1"), d("3"), 38, Rounding.HalfEven);
    guard let third = r else { panic("1/3"); }
    assert(format(third) == "0.33333333333333333333333333333333333333", format(third));
    let r2 = div(d("12345678901234567890.123456789"), d("98765432109876543210.98765"),
                 30, Rounding.HalfEven);
    guard let q = r2 else { panic("long division"); }
    assert(format(q) == "0.124999998860937500014238286719", format(q));
    let r3 = div(d("10"), d("4"), 0, Rounding.HalfEven);
    assert(format(r3 ?? zero()) == "2", "2.5 to even");
    let r4 = div(d("-7"), d("2"), 0, Rounding.Floor);
    assert(format(r4 ?? zero()) == "-4", "floor of -3.5");
}

fn test_should_compare_by_value() {
    assert(eq(d("1.5"), d("1.50")), "1.5 eq 1.50");
    assert(format(d("1.5")) != format(d("1.50")), "the scale is kept");
    assert(lt(d("-1"), d("0.1")), "lt");
    assert(gt(d("0.1"), d("-1")), "gt");
    assert(le(d("2"), d("2.0")) && ge(d("2"), d("2.0")), "le ge");
    assert(eq(min(d("3"), d("2.99")), d("2.99")), "min");
    assert(eq(max(d("-3"), d("-2.99")), d("-2.99")), "max");
    assert(cmp(d("0"), d("-0.0")) == 0, "zero against negative zero");
    assert(sign(d("-0.001")) == -1 && sign(d("0.00")) == 0 && sign(d("5")) == 1, "sign");
}

fn test_should_normalize_and_count_digits() {
    assert(format(normalize(d("1.500"))) == "1.5", "1.500");
    assert(format(normalize(d("2.00"))) == "2", "2.00");
    assert(format(normalize(d("-0.000"))) == "0", "zero");
    assert(format(normalize(d("100"))) == "100", "integer zeros stay");
    assert(precision(d("0.00123")) == 3, "precision");
    assert(precision(d("0")) == 1, "precision of zero");
    assert(format(neg(d("0"))) == "0", "neg of zero");
    assert(format(abs(d("-4.20"))) == "4.20", "abs");
}

// ---- splitting money -------------------------------------------------------

fn sum_of(parts: [Decimal]) -> Decimal {
    let s = zero();
    for p in parts {
        s = add(s, p) ?? zero();
    }
    return s;
}

fn test_should_split_without_losing_a_unit() {
    let parts = split(d("100.00"), 3);
    assert(len(parts) == 3, "three parts");
    assert(format(parts[0]) == "33.34" && format(parts[1]) == "33.33"
           && format(parts[2]) == "33.33", format(parts[0]));
    assert(eq(sum_of(parts), d("100.00")), "sums back");
    let neg_parts = split(d("-0.05"), 2);
    assert(format(neg_parts[0]) == "-0.03" && format(neg_parts[1]) == "-0.02", "negative");
    assert(len(split(d("1"), 0)) == 0, "zero parts");
    // invariant over many amounts and counts
    for i in 1..60 {
        let amount = from_units(i * 7919 - 200000, 2) ?? zero();
        let ps = split(amount, i % 9 + 1);
        assert(eq(sum_of(ps), amount), "split sum for " + format(amount));
    }
}

fn test_should_allocate_by_weight() {
    let r = allocate(d("10.00"), [1, 2]);
    guard let ps = r else let e = err_of(r) { panic(e); }
    assert(format(ps[0]) == "3.33" && format(ps[1]) == "6.67", format(ps[0]) + " " + format(ps[1]));
    let r2 = allocate(d("0.05"), [1, 1, 1]);
    guard let q = r2 else { panic("0.05"); }
    assert(format(q[0]) == "0.02" && format(q[1]) == "0.02" && format(q[2]) == "0.01",
           "earlier parts take ties");
    let r3 = allocate(d("100"), [0, 5, 0]);
    guard let z = r3 else { panic("zero weights"); }
    assert(format(z[0]) == "0" && format(z[1]) == "100" && format(z[2]) == "0", "zero weights");
    assert(!list_ok(allocate(d("1"), [])), "no weights");
    assert(!list_ok(allocate(d("1"), [1, -1])), "negative weight");
    assert(!list_ok(allocate(d("1"), [0, 0])), "zero sum");
    // large weights go through the general divisor path
    let r4 = allocate(d("1000000.000000"), [3000000000, 7000000000, 1]);
    guard let big = r4 else { panic("big weights"); }
    assert(eq(sum_of(big), d("1000000.000000")), "big weights sum back");
}

fn strings_has(s: str, sub: str) -> bool {
    return strings.contains(s, sub);
}

fn is_ok(r: result[Decimal, str]) -> bool {
    if let v = r {
        return true;
    }
    return false;
}

fn is_some(o: opt[Decimal]) -> bool {
    if let v = o {
        return true;
    }
    return false;
}

fn list_ok(r: result[[Decimal], str]) -> bool {
    if let v = r {
        return true;
    }
    return false;
}

fn int_some(o: opt[int]) -> bool {
    if let v = o {
        return true;
    }
    return false;
}

// Knuth's add-back step (a quotient-limb estimate one too large after
// both corrections) happens about twice in 10^9 limbs, so random vectors
// never reach it. These three were found by searching for inputs that
// take it, with an emulation of w_divmod; expected values are exact
// rationals rounded half-even.
fn check_div(a: str, b: str, scale: int, want: str) {
    let r = div(d(a), d(b), scale, Rounding.HalfEven);
    guard let q = r else let e = err_of(r) { panic(e); }
    assert(format(q) == want, a + " / " + b + ": got " + format(q) + ", want " + want);
}

fn test_should_divide_through_the_add_back_step() {
    check_div("500000000000000000500000000", "500000000000000000999999998499999999", 14, "0.00000000100000");
    check_div("999999998999999999", "499999999499999999999999998", 33, "0.000000001999999999999999998000000");
    check_div("499999999", "999999998000000000499999999", 31, "0.0000000000000000005000000000000");
}
