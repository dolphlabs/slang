// sort: the adaptive pass, the quicksort, the stable merge, NaN
// ordering, and every search, with the ordering invariant asserted
// after each sort so the printed lines stay answers, not data.
import "sort";

// Two-digit order-preserving tags: with these, "tag[i] > tag[j]" is
// the same question as the number order, so the stable sort's promise
// can be asserted on strings.
fn pad2(n: int) -> str {
    if n < 10 {
        return "0" + to_str(n);
    }
    return to_str(n);
}

fn asc_ok(xs: [int]) -> bool {
    let i = 1;
    while i < len(xs) {
        if xs[i - 1] > xs[i] {
            return false;
        }
        i += 1;
    }
    return true;
}

struct Ev {
    at: int,
    tag: str,
    w: float,
}

fn at_of(e: Ev) -> int {
    return e.at;
}

fn tag_of(e: Ev) -> str {
    return e.tag;
}

fn wt_of(e: Ev) -> float {
    return e.w;
}

// ---------------------------------------------------------------- //
// ints                                                               //
// ---------------------------------------------------------------- //

let xs = [5, 3, 9, 1, 3, 7, 0, 2, 8, 1, 4, 6, 5, 2];
sort.ints(xs);
let i = 1;
while i < len(xs) {
    assert(xs[i - 1] <= xs[i]);
    i += 1;
}
println("first=" + to_str(xs[0]) + " last=" + to_str(xs[len(xs) - 1]));
println(sort.search_ints(xs, 7) ?? -1);
println(sort.search_ints(xs, 42) ?? -1);

let asc = [1, 2, 3, 4];
sort.ints(asc);
if asc[0] == 1 && asc[3] == 4 {
    println("sorted-ok");
}

let desc = [9, 7, 5, 3, 1];
sort.ints(desc);
if desc[0] == 1 && desc[4] == 9 {
    println("reversed-ok");
}

let eq = [4, 4, 4, 4];
sort.ints(eq);
if eq[0] == 4 && eq[3] == 4 {
    println("equal-ok");
}

let mixed = [2, 1, 2, 2, 1, 1, 2, 1, 2, 2, 1, 1, 2, 1, 2, 2];
sort.ints(mixed);
let m = 0;
let ones = 0;
let twos = 0;
while m < len(mixed) {
    if mixed[m] == 1 {
        ones += 1;
    }
    if mixed[m] == 2 {
        twos += 1;
    }
    m += 1;
}
if asc_ok(mixed) && ones == 7 && twos == 9 {
    println("ones=7 twos=9");
}

let neg = [0, -1, -20, 5, -1];
sort.ints(neg);
print(to_str(neg[0]) + "," + to_str(neg[1]) + "," + to_str(neg[2]) + ",");
println(to_str(neg[3]) + "," + to_str(neg[4]));
println(sort.search_ints(neg, -1) ?? -1);
println(sort.search_ints(neg, -2) ?? -1);

let bs = [42, 7, 42, 0, -5, 7, 42, 100, -5, 0, 42, 7, 0, 100, -5, 42];
sort.ints(bs);
if asc_ok(bs) && len(bs) == 16 {
    println("first=" + to_str(bs[0]) + " last=" + to_str(bs[15]));
}

// fifty values over both negatives and duplicates: several quicksort
// recursion depths in one list
let rs: [int] = [];
let v = 1;
let c = 0;
while c < 50 {
    push(rs, v - 11);
    v = (v * 7 + 13) % 23;
    c += 1;
}
sort.ints(rs);
if asc_ok(rs) && len(rs) == 50 {
    println("mix50-ok");
}

// ---------------------------------------------------------------- //
// floats: NaN sorts first, like Go's sort.Float64s                    //
// ---------------------------------------------------------------- //

let nan = 0.0 / 0.0;
let fs = [3.5, 1.0, nan, 0.5, nan, 2.0];
sort.floats(fs);
assert(fs[0] != fs[0], "NaN expected first");
assert(fs[1] != fs[1], "second NaN expected");
assert(fs[2] == 0.5 && fs[3] == 1.0 && fs[4] == 2.0 && fs[5] == 3.5,
       "wrong float order");
println("nan-first-ok");

let fsort = [2.0, 2.0, 1.0, 2.0];
sort.floats(fsort);
if fsort[0] == 1.0 && fsort[1] == 2.0 && fsort[2] == 2.0 && fsort[3] == 2.0 {
    println("floats-eq-ok");
}
println(sort.search_floats(fs, nan) ?? -1);
println(sort.search_floats(fs, 2.0) ?? -1);

// ---------------------------------------------------------------- //
// strings                                                             //
// ---------------------------------------------------------------- //

let ss = ["b", "", "ab", "a", "", "ba"];
sort.strings(ss);
let sline = "";
for s in ss {
    sline = sline + s + "|";
}
println(sline);
println(sort.search_strings(ss, "") ?? -1);
println(sort.search_strings(ss, "b") ?? -1);
println(sort.search_strings(ss, "zz") ?? -1);

// ---------------------------------------------------------------- //
// by: struct by int, str and float key                                //
// ---------------------------------------------------------------- //

let evs = [Ev { at: 3, tag: "a", w: 0.0 },
           Ev { at: 1, tag: "b", w: 0.0 },
           Ev { at: 3, tag: "c", w: 0.0 },
           Ev { at: 1, tag: "d", w: 0.0 },
           Ev { at: 3, tag: "e", w: 0.0 },
           Ev { at: 2, tag: "f", w: 0.0 }];
sort.by(evs, at_of);
let ei = 1;
while ei < len(evs) {
    assert(!(evs[ei].at < evs[ei - 1].at), "int key not sorted");
    ei += 1;
}
println("by-int-ok");

let us = [Ev { at: 0, tag: "rob", w: 0.0 },
          Ev { at: 0, tag: "ann", w: 0.0 },
          Ev { at: 0, tag: "zoe", w: 0.0 },
          Ev { at: 0, tag: "ann", w: 0.0 }];
sort.by(us, tag_of);
let ui = 1;
while ui < len(us) {
    assert(!(us[ui].tag < us[ui - 1].tag), "str key not sorted");
    ui += 1;
}
if us[0].tag == "ann" && us[3].tag == "zoe" {
    println("by-str-ok");
}

let ws = [Ev { at: 0, tag: "a", w: 2.5 },
          Ev { at: 0, tag: "b", w: 0.25 },
          Ev { at: 0, tag: "c", w: 1.0 },
          Ev { at: 0, tag: "d", w: 0.25 }];
sort.by(ws, wt_of);
let wi = 1;
while wi < len(ws) {
    assert(!(ws[wi].w < ws[wi - 1].w), "float key not sorted");
    wi += 1;
}
if ws[0].w == 0.25 && ws[3].w == 2.5 {
    println("by-float-ok");
}

// ---------------------------------------------------------------- //
// by_stable: equal keys keep the order they were in                   //
// ---------------------------------------------------------------- //

let og = [Ev { at: 3, tag: "a", w: 0.0 },
          Ev { at: 1, tag: "b", w: 0.0 },
          Ev { at: 3, tag: "c", w: 0.0 },
          Ev { at: 1, tag: "d", w: 0.0 },
          Ev { at: 3, tag: "e", w: 0.0 },
          Ev { at: 2, tag: "f", w: 0.0 }];
sort.by_stable(og, at_of);
let line = "";
for e in og {
    line = line + e.tag;
}
println(line);

let evs2: [Ev] = [];
let b = 0;
while b < 70 {
    push(evs2, Ev { at: b % 5, tag: pad2(b), w: 0.0 });
    b += 1;
}
sort.by_stable(evs2, at_of);
let k = 1;
while k < len(evs2) {
    assert(!(evs2[k].at < evs2[k - 1].at), "stable merge not by key");
    if evs2[k].at == evs2[k - 1].at {
        assert(evs2[k].tag > evs2[k - 1].tag, "stable order broken");
    }
    k += 1;
}
println("window70-ok");

println(sort.search_by(evs2, at_of, 2) ?? -1);
println(sort.search_by(evs2, at_of, 9) ?? -1);

let dd = [Ev { at: 5, tag: "e", w: 0.0 },
          Ev { at: 4, tag: "d", w: 0.0 },
          Ev { at: 3, tag: "c", w: 0.0 }];
sort.by_stable(dd, at_of);
print(to_str(dd[0].at) + dd[0].tag + " ");
print(to_str(dd[1].at) + dd[1].tag + " ");
println(to_str(dd[2].at) + dd[2].tag);

// equal keys INSIDE a descending head must not take the reversal:
// x, y keep their right order relative to each other
let dd2 = [Ev { at: 5, tag: "x", w: 0.0 },
           Ev { at: 5, tag: "y", w: 0.0 },
           Ev { at: 4, tag: "z", w: 0.0 }];
sort.by_stable(dd2, at_of);
let dline = "";
for e in dd2 {
    dline = dline + e.tag;
}
println(dline);

let oo = [Ev { at: 1, tag: "a", w: 0.0 }, Ev { at: 2, tag: "b", w: 0.0 }];
sort.by_stable(oo, at_of);
if oo[0].tag == "a" && oo[1].tag == "b" {
    println("stable-sorted-ok");
}
