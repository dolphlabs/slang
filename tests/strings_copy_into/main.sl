// strings.copy_into: one memmove for a byte range, with the forward,
// byte-by-byte result an LZ77 decoder needs when the ranges overlap.
import "strings";

fn check(name: str, ok: bool) {
    if ok {
        println("ok   " + name);
    } else {
        println("FAIL " + name);
    }
}

// The loop copy_into replaces: forward, one byte at a time.
fn slow_copy(dst: bytes, at: int, src: bytes, from: int, to: int) -> int {
    for i in 0..(to - from) {
        dst[at + i] = src[from + i];
    }
    return at + (to - from);
}

fn fill(n: int, seed: int) -> bytes {
    let b = strings.bytes_zero(n);
    for i in 0..n {
        b[i] = (i * 31 + seed * 7 + 11) & 255;
    }
    return b;
}

// separate buffers
let d = strings.bytes_zero(10);
let end = strings.copy_into(d, 3, b"abcdef", 1, 5);
check("returns the end", end == 7);
check("copies the range", to_str(d[3..7]) == "bcde");
check("leaves the rest", d[0] == 0 && d[2] == 0 && d[7] == 0 && d[9] == 0);
check("empty range", strings.copy_into(d, 10, b"xyz", 2, 2) == 10);
check("whole buffer", strings.copy_into(d, 0, b"0123456789", 0, 10) == 10 && to_str(d) == "0123456789");

// the same buffer, destination before the source: a plain shift left
let l = to_bytes("0123456789");
strings.copy_into(l, 1, l, 3, 9);
check("overlap, shift left", to_str(l) == "0345678789");

// the same buffer, destination after the source: the LZ77 repeat
let r = to_bytes("abc.........");
strings.copy_into(r, 3, r, 0, 9);
check("overlap, period 3", to_str(r) == "abcabcabcabc");
let one = to_bytes("x.......");
strings.copy_into(one, 1, one, 0, 7);
check("overlap, period 1", to_str(one) == "xxxxxxxx");

// against the loop, for every period and length up to 40
let all = true;
for period in 1..20 {
    for k in 0..40 {
        let n = period + k + 5;
        let a = fill(n, period + k);
        let b = fill(n, period + k);
        let ea = strings.copy_into(a, 2 + period, a, 2, 2 + k);
        let eb = slow_copy(b, 2 + period, b, 2, 2 + k);
        if ea != eb || a != b {
            all = false;
        }
    }
}
check("matches the byte loop, overlapping", all);

let all2 = true;
for k in 0..300 {
    let src = fill(k + 7, k);
    let a = fill(k + 20, 3);
    let b = fill(k + 20, 3);
    strings.copy_into(a, 9, src, 4, 4 + k);
    slow_copy(b, 9, src, 4, 4 + k);
    if a != b {
        all2 = false;
    }
}
check("matches the byte loop, separate", all2);
