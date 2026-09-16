// to_int / to_float: the inverse of to_str, and fallible because
// parsing genuinely is.
//
// These replace `extern fn atoi`, which the demos used to reach for.
// atoi returns 0 for "abc", 80 for "80x80" and 0 for "", reporting
// nothing in any case -- so `PORT=abc` bound an ephemeral port and said
// nothing about it. Every one of those is an error here.

fn shown(s: str) {
    let r = to_int(s);
    guard let n = r else let e = err_of(r) {
        println(s + " -> err: " + e);
        return;
    }
    println(s + " -> " + to_str(n));
}

shown("8080");
shown("-42");
shown("+7");
shown("0");
shown("abc");          // atoi: 0
shown("80x80");        // atoi: 80
shown("");             // atoi: 0
shown("  12");         // leading space is not silently skipped
shown("12 ");
shown("1_000");
shown("0x10");
shown("-");

// The int64 boundaries: the negative limit is one larger than the
// positive one, so the range check is derived from the sign rather
// than assumed symmetric.
shown("9223372036854775807");
shown("-9223372036854775808");
shown("9223372036854775808");
shown("-9223372036854775809");

fn shownf(s: str) {
    let r = to_float(s);
    guard let f = r else let e = err_of(r) {
        println(s + " -> err: " + e);
        return;
    }
    println(s + " -> " + to_str(f));
}

shownf("3.5");
shownf("-0.25");
shownf("1e3");
shownf("0");
shownf("inf");         // strtod would accept these; they are almost
shownf("nan");         // never what a config value meant
shownf("1.5x");
shownf("");

// `??` works on the result, for callers that genuinely have a default
println(to_int("nope") ?? -1);
println(to_int("77") ?? -1);
println("done");
