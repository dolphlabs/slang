// Numeric `+` keeps a loop on the leaf path (hoisted bracket plus a
// per-iteration poll). Before, any `+` disqualified a loop because it
// might be a concat, so `i = i + 1` -- in nearly every scan loop -- cost a
// full safepoint per iteration. run_tests.sh counts the polls: the first
// five functions must avoid the per-iteration bracket, the last three must not (a str
// concat allocates, and a name rebound inside the loop cannot be trusted
// to keep its outer type). Runs under the GC stress lists so the loops
// keep their live bytes and lists across forced minors.
fn copy_at(dst: bytes, at: int, src: bytes) -> int {
    let i = 0;
    let n = len(src);
    while i < n {
        dst[at + i] = src[i];
        i = i + 1;
    }
    return i;
}

fn sum_compound(t: [int]) -> int {
    let total = 0;
    let i = 0;
    while i < len(t) {
        total += t[i] * 2;
        i += 1;
    }
    return total;
}

fn range_sum(t: [int], bias: int) -> int {
    let total = 0;
    for j in 0..len(t) {
        total = total + j + bias - t[j];
    }
    return total;
}

fn varint_len(b: bytes, from: int) -> int {
    let pos = from;
    let shift = 0;
    while pos < len(b) && b[pos] >= 128 && shift < 63 {
        pos = pos + 1;
        shift = shift + 7;
    }
    return pos + 1 - from;
}

fn float_acc(xs: [float]) -> float {
    let acc = 0.5;
    let i = 0;
    while i < len(xs) {
        acc = acc + xs[i] + (i as float);
        i = i + 1;
    }
    return acc;
}

fn concat_loop(n: int) -> str {
    let s = "";
    let i = 0;
    while i < n {
        s = s + "x";
        i = i + 1;
    }
    return s;
}

// The inner `k` is a str: from the loop head var_find still sees the outer
// int `k`, so trusting it would call `k + k` numeric and skip the bracket
// around an allocation.
fn shadowed(xs: [int]) -> int {
    let k = 1;
    let total = 0;
    let i = 0;
    while i < len(xs) {
        let k = "ab";
        let m = k + k;
        total = total + len(m) + xs[i];
        i = i + 1;
    }
    return total + k;
}

fn index_plus(xs: [str]) -> str {
    let out = "";
    let i = 0;
    while i < len(xs) {
        out = xs[i] + out;
        i = i + 1;
    }
    return out;
}

let src = b"\x81\x82\x83\x04";
let dst = b"\x00\x00\x00\x00\x00\x00";
println(copy_at(dst, 2, src));
println(dst[2] == 129 && dst[5] == 4);
let t: [int] = [1, 2, 3, 4, 5];
println(sum_compound(t));
println(range_sum(t, 10));
println(varint_len(src, 0));
let xs: [float] = [1.0, 2.0];
println(float_acc(xs));
println(concat_loop(3));
println(shadowed(t));
let words: [str] = ["a", "b", "c"];
println(index_plus(words));
