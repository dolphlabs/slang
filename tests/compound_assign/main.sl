// Compound assignment: x op= v, desugared to x = x op v.
//
// The desugaring evaluates the target twice, so the parser restricts the
// target to shapes with no function call in them. Everything below is
// safe to re-evaluate; tests/fail_compound_* pin the rejections.

struct Counter { hits: int, mask: int }

fn bump(c: [int]) -> int {
    c[0] = c[0] + 1;
    return 0;
}

fn ck(name: str, got: int, want: int) -> int {
    if got != want {
        println("FAIL " + name + ": got " + to_str(got) + " want " + to_str(want));
        return 1;
    }
    return 0;
}

let fails = 0;

// ---- arithmetic on a plain name ---------------------------------
let x = 10;
x += 5;   fails = fails + ck("add", x, 15);
x -= 3;   fails = fails + ck("sub", x, 12);
x *= 4;   fails = fails + ck("mul", x, 48);
x /= 2;   fails = fails + ck("div", x, 24);
x %= 7;   fails = fails + ck("mod", x, 3);

// ---- bitwise ------------------------------------------------------
x |= 8;    fails = fails + ck("or", x, 11);
x &= 12;   fails = fails + ck("and", x, 8);
x ^= 5;    fails = fails + ck("xor", x, 13);
x <<= 3;   fails = fails + ck("shl", x, 104);
x >>= 2;   fails = fails + ck("shr", x, 26);

// ---- list elements, including a computed (but pure) index --------
let xs = [1, 2, 3, 4];
xs[0] += 10;      fails = fails + ck("index-const", xs[0], 11);
let i = 1;
xs[i] *= 5;       fails = fails + ck("index-name", xs[1], 10);
xs[i + 1] <<= 4;  fails = fails + ck("index-expr", xs[2], 48);
xs[3] |= 0b1000;  fails = fails + ck("index-bin-literal", xs[3], 12);

// ---- pure builtins in the index (no temporary needed) ------------
let ys = [1, 2, 3, 4];
ys[len(ys) - 1] += 10;   fails = fails + ck("len-index", ys[3], 14);
ys[len(ys) - 2] <<= 3;   fails = fails + ck("len-index-shl", ys[2], 24);

// ---- a SIDE-EFFECTING index runs exactly once --------------------
// The desugaring names the target twice, so an impure index is hoisted
// into a temporary first. If it were not, every call below would run
// twice and these counts would be wrong.
let popped = [2];
let ps = [10, 20, 30];
ps[pop(popped)] += 5;
fails = fails + ck("impure-index-value", ps[2], 35);
fails = fails + ck("impure-index-once", len(popped), 0);

let calls = [0];
let qs = [100, 200];
qs[bump(calls)] += 7;
fails = fails + ck("counted-index-value", qs[0], 107);
fails = fails + ck("counted-index-once", calls[0], 1);

// and once per iteration inside a loop, with a fresh temporary
let ws = [0, 0, 0];
let src = [2, 1, 0];
for step in 0..3 {
    ws[pop(src)] += 1;
}
fails = fails + ck("loop-impure-0", ws[0], 1);
fails = fails + ck("loop-impure-1", ws[1], 1);
fails = fails + ck("loop-impure-2", ws[2], 1);
fails = fails + ck("loop-impure-drained", len(src), 0);

// ---- map values ---------------------------------------------------
let m: map[str]int = {"a": 1, "b": 2};
m["a"] += 41;     fails = fails + ck("map-str-key", m["a"], 42);
let k = "b";
m[k] <<= 3;       fails = fails + ck("map-name-key", m["b"], 16);

// ---- struct fields ------------------------------------------------
let c = Counter { hits: 0, mask: 0 };
c.hits += 7;      fails = fails + ck("field-add", c.hits, 7);
c.mask |= 0xf0;   fails = fails + ck("field-or", c.mask, 240);
c.mask &= 0x30;   fails = fails + ck("field-and", c.mask, 48);

// ---- str += concatenates, same as str + ---------------------------
let s = "a";
s += "b";
s += 5;
if s != "ab5" {
    println("FAIL str-concat: got " + s);
    fails = fails + 1;
}

// ---- float ---------------------------------------------------------
let f = 1.5;
f *= 2.0;
if f != 3.0 {
    println("FAIL float-mul");
    fails = fails + 1;
}

// ---- the loop this was built for ----------------------------------
let acc = 0;
for b in 0..8 {
    acc |= 1 << b;
}
fails = fails + ck("mask-loop", acc, 255);

// evaluating the target twice must not double any side effect: this
// would be 2 if the desugaring re-ran an increment rather than reusing
// the value.
let n = 0;
n += 1;
fails = fails + ck("no-double-apply", n, 1);

if fails == 0 {
    println("all compound assignment checks passed");
} else {
    println("FAILURES: " + to_str(fails));
    exit(1);
}
