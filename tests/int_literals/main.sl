// Integer literal ranges and bases.
//
// The regression this exists for: decimal literals used to go through
// strtoll, which SATURATES at LLONG_MAX on overflow. 18446744073709551615,
// 9223372036854775808 and 99999999999999999999999 all silently became
// 9223372036854775807 -- three different wrong answers, no diagnostic.

fn ck(name: str, got: int, want: int) -> int {
    if got != want {
        println("FAIL " + name + ": got " + to_str(got) + " want " + to_str(want));
        return 1;
    }
    return 0;
}

let fails = 0;

// ---- bases -------------------------------------------------------
fails = fails + ck("dec", 255, 255);
fails = fails + ck("hex-lower", 0xff, 255);
fails = fails + ck("hex-upper", 0xFF, 255);
fails = fails + ck("hex-mixed", 0xDeAd, 57005);
fails = fails + ck("bin", 0b1111, 15);
fails = fails + ck("zero", 0, 0);
fails = fails + ck("hex-zero", 0x0, 0);

// ---- digit separators --------------------------------------------
fails = fails + ck("sep-dec", 1_000_000, 1000000);
fails = fails + ck("sep-hex", 0xdead_beef, 3735928559);
fails = fails + ck("sep-bin", 0b1111_0000, 240);

// ---- i64 boundary -------------------------------------------------
fails = fails + ck("i64-max", 9223372036854775807, 9223372036854775807);
fails = fails + ck("i64-min", -9223372036854775807 - 1,
                   -9223372036854775807 - 1);

// ---- above i64: types as u64, keeps its value ---------------------
// Each of these used to be 9223372036854775807.
let a: u64 = 18446744073709551615;
let b: u64 = 9223372036854775808;
let c: u64 = 0xffff_ffff_ffff_ffff;
if a != c {
    println("FAIL u64-max decimal vs hex disagree");
    fails = fails + 1;
}
if b >= a {
    println("FAIL 2^63 should be less than 2^64-1");
    fails = fails + 1;
}
if (a >> 32) as int != 4294967295 {
    println("FAIL u64-max high half");
    fails = fails + 1;
}
if (b >> 63) as int != 1 {
    println("FAIL 2^63 top bit");
    fails = fails + 1;
}
// an unannotated literal above i64 infers u64 rather than wrapping
let d = 18446744073709551615;
if (d >> 60) as int != 15 {
    println("FAIL inferred u64");
    fails = fails + 1;
}

// ---- narrow targets still accept literals that fit ----------------
let e8: u8 = 255;
let f8: i8 = -128;
let g32: u32 = 4294967295;
fails = fails + ck("u8-max", e8 as int, 255);
fails = fails + ck("i8-min", f8 as int, -128);
fails = fails + ck("u32-max", g32 as int, 4294967295);

if fails == 0 {
    println("all integer literal checks passed");
} else {
    println("FAILURES: " + to_str(fails));
    exit(1);
}
