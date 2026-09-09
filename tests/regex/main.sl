import "regex";

fn ck(name: str, got: bool, want: bool) -> int {
    if got && !want {
        println("FAIL " + name + " (expected no match)");
        return 1;
    }
    if !got && want {
        println("FAIL " + name + " (expected match)");
        return 1;
    }
    return 0;
}

fn m(pat: str, subj: str) -> bool {
    let cr = regex.compile(pat);
    guard let re = cr else let e = err_of(cr) {
        println("FAIL compile " + pat + ": " + e);
        return false;
    }
    let r = regex.is_match(re, subj);
    regex.free(re);
    return r;
}

let fails = 0;

// ---- literals, wildcards, classes -------------------------------
fails = fails + ck("literal", m("abc", "xxabcyy"), true);
fails = fails + ck("literal-no", m("abc", "xxabyy"), false);
fails = fails + ck("dot", m("a.c", "abc"), true);
fails = fails + ck("dot-not-newline", m("a.c", "a\nc"), false);
fails = fails + ck("class", m("[bcd]", "zzcz"), true);
fails = fails + ck("class-neg", m("^[^abc]+$", "aab"), false);
fails = fails + ck("range", m("[a-f]+", "zzzdef"), true);
fails = fails + ck("posix", m("[[:digit:]]{3}", "ab123"), true);

// ---- escapes -----------------------------------------------------
fails = fails + ck("digit", m("\\d+", "abc123"), true);
fails = fails + ck("digit-anchored", m("^\\d+$", "12a"), false);
fails = fails + ck("word", m("\\w+", "__x"), true);
fails = fails + ck("space", m("a\\sb", "a\tb"), true);
fails = fails + ck("nondigit", m("\\D", "1a"), true);
fails = fails + ck("esc-dot", m("^a\\.c$", "a.c"), true);
fails = fails + ck("esc-dot-literal", m("^a\\.c$", "abc"), false);
fails = fails + ck("esc-hex", m("^\\x41$", "A"), true);

// ---- anchors and boundaries -------------------------------------
fails = fails + ck("anchor-start", m("^abc", "abcd"), true);
fails = fails + ck("anchor-start-no", m("^abc", "xabcd"), false);
fails = fails + ck("anchor-end", m("abc$", "xxabc"), true);
fails = fails + ck("anchor-end-no", m("abc$", "abcx"), false);
fails = fails + ck("wordb", m("\\bcat\\b", "a cat here"), true);
fails = fails + ck("wordb-no", m("\\bcat\\b", "concatenate"), false);

// ---- quantifiers -------------------------------------------------
fails = fails + ck("star-zero", m("^ab*c$", "ac"), true);
fails = fails + ck("star-many", m("^ab*c$", "abbbc"), true);
fails = fails + ck("plus-needs-one", m("^ab+c$", "ac"), false);
fails = fails + ck("quest", m("^ab?c$", "ac"), true);
fails = fails + ck("rep-exact", m("^a{3}$", "aaa"), true);
fails = fails + ck("rep-exact-no", m("^a{3}$", "aa"), false);
fails = fails + ck("rep-range", m("^a{2,4}$", "aaa"), true);
fails = fails + ck("rep-range-over", m("^a{2,4}$", "aaaaa"), false);
fails = fails + ck("rep-open", m("^a{2,}$", "aaaaa"), true);
fails = fails + ck("lazy", m("^a+?b$", "aaab"), true);

// ---- alternation and groups -------------------------------------
fails = fails + ck("alt", m("^(cat|dog|bird)$", "dog"), true);
fails = fails + ck("alt-no", m("^(cat|dog|bird)$", "fish"), false);
fails = fails + ck("nested", m("^((a|b)+c)+$", "abcabc"), true);
fails = fails + ck("noncapturing", m("^(?:ab)+$", "abab"), true);

// ---- captures ----------------------------------------------------
let cr = regex.compile("(\\d{4})-(\\d{2})-(\\d{2})");
guard let re = cr else let e = err_of(cr) {
    println("FAIL compile date: " + e);
    exit(1);
}
if regex.groups(re) != 3 {
    println("FAIL group count");
    fails = fails + 1;
}
let mm = regex.find(re, "due 2026-09-09 ok");
if len(mm) != 8 {
    println("FAIL find slot count " + to_str(len(mm)));
    fails = fails + 1;
} else {
    if mm[0] != 4 || mm[1] != 14 { println("FAIL whole-match span"); fails = fails + 1; }
    if mm[2] != 4 || mm[3] != 8 { println("FAIL group 1 span"); fails = fails + 1; }
    if mm[4] != 9 || mm[5] != 11 { println("FAIL group 2 span"); fails = fails + 1; }
    if mm[6] != 12 || mm[7] != 14 { println("FAIL group 3 span"); fails = fails + 1; }
}
let nomatch = regex.find(re, "nothing here");
if len(nomatch) != 0 {
    println("FAIL no-match should be empty");
    fails = fails + 1;
}
regex.free(re);

// ---- bytes: explicit length, so embedded NUL is an ordinary byte -
let br = regex.compile("w\\x00rld");
guard let bre = br else let e = err_of(br) {
    println("FAIL bytes compile: " + e);
    exit(1);
}
fails = fails + ck("NUL inside subject", regex.is_match_bytes(bre, b"hello w\x00rld!"), true);
regex.free(bre);

let nr = regex.compile("a\\Db");
guard let nre = nr else let e = err_of(nr) {
    println("FAIL nul-class compile: " + e);
    exit(1);
}
fails = fails + ck("\\D matches NUL", regex.is_match_bytes(nre, b"a\x00b"), true);
regex.free(nre);

// ---- find_at: walk every match ----------------------------------
let ir = regex.compile("[0-9]+");
guard let ire = ir else let e = err_of(ir) {
    println("FAIL iter compile: " + e);
    exit(1);
}
let subj = "a1 bb22 ccc333 d4";
let at = 0;
let found = 0;
while at <= len(subj) {
    let one = regex.find_at(ire, subj, at);
    if len(one) == 0 { break; }
    found = found + 1;
    if one[1] == one[0] { at = one[1] + 1; } else { at = one[1]; }
}
if found != 4 {
    println("FAIL iterated " + to_str(found) + " matches, want 4");
    fails = fails + 1;
}
regex.free(ire);

// ---- linear time: the ReDoS bomb must not blow up ---------------
// A backtracking engine goes exponential on this. If this engine ever
// regresses to backtracking, this test stops terminating.
let dr = regex.compile("^(a+)+$");
guard let dre = dr else let e = err_of(dr) {
    println("FAIL redos compile: " + e);
    exit(1);
}
let bomb = "";
for i in 0..40 { bomb = bomb + "a"; }
bomb = bomb + "b";
fails = fails + ck("redos-bomb terminates", regex.is_match(dre, bomb), false);
regex.free(dre);

// ---- compile errors stay visible through err_of -----------------
let e1 = regex.compile("(unclosed");
guard let _a = e1 else let e = err_of(e1) { println("err: " + e); }
let e2 = regex.compile("a{2,1}");
guard let _b = e2 else let e = err_of(e2) { println("err: " + e); }
let e3 = regex.compile("*x");
guard let _c = e3 else let e = err_of(e3) { println("err: " + e); }
let e4 = regex.compile("(?=lookahead)");
guard let _d = e4 else let e = err_of(e4) { println("err: " + e); }
let e5 = regex.compile("[z-a]");
guard let _e = e5 else let e = err_of(e5) { println("err: " + e); }

// nesting past the cap is an error, not a crash
let deep = "";
for i in 0..200 { deep = deep + "(?:"; }
deep = deep + "a";
for i in 0..200 { deep = deep + ")"; }
let e6 = regex.compile(deep);
guard let _f = e6 else let e = err_of(e6) { println("err: " + e); }

if fails == 0 {
    println("all regex checks passed");
} else {
    println("FAILURES: " + to_str(fails));
    exit(1);
}
