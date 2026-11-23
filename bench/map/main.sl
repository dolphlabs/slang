// The built-in map on its own, without a cache around it.
//
//     main str_hit|str_miss|str_long|str_put|str_del|int_hit|int_put
//
// 100,000 keys. Lookups use separately built strings with the same bytes,
// so a hit always compares contents, never just a pointer. Draws are an
// xorshift, the same sequence on every run. Prints ns_per_op and a
// checksum that keeps the loop from being optimised away.

import "proc";
import "time";

let n = 100000;

fn short_keys(n: int, salt: str) -> [str] {
    let ks: [str] = [];
    for i in 0..n {
        push(ks, salt + to_str(i * 7919 % 1000003));
    }
    return ks;
}

// 64-byte keys sharing a 48-byte prefix, like URLs or header names
fn long_keys(n: int) -> [str] {
    let ks: [str] = [];
    let prefix = "https://api.example.com/v1/accounts/0000/items/";
    for i in 0..n {
        let tail = to_str(1000000000000000 + i * 7919 % 1000003);
        push(ks, prefix + tail);
    }
    return ks;
}

fn next(state: [int]) -> int {
    let x = state[0];
    x = x ^ (x << 13);
    x = x ^ ((x >> 7) & 144115188075855871);
    x = x ^ (x << 17);
    state[0] = x;
    return x & 9223372036854775807;
}

fn fill(ks: [str]) -> map[str]int {
    let m: map[str]int = {};
    for i in 0..len(ks) {
        m[ks[i]] = i;
    }
    return m;
}

fn lookups(m: map[str]int, probe: [str], ops: int) -> int {
    let state = [88172645463325252];
    let sum = 0;
    for _ in 0..ops {
        let k = probe[next(state) % len(probe)];
        if has(m, k) {
            sum += m[k];
        }
    }
    return sum;
}

let mode = proc.args()[1];
let ops = 2000000;
let sum = 0;
let t0 = time.mono();
if mode == "str_hit" {
    let m = fill(short_keys(n, "user:"));
    let probe = short_keys(n, "user:");
    t0 = time.mono();
    sum = lookups(m, probe, ops);
} else if mode == "str_miss" {
    let m = fill(short_keys(n, "user:"));
    let probe = short_keys(n, "gone:");
    t0 = time.mono();
    sum = lookups(m, probe, ops);
} else if mode == "str_long" {
    let m = fill(long_keys(n));
    let probe = long_keys(n);
    t0 = time.mono();
    sum = lookups(m, probe, ops);
} else if mode == "str_put" {
    let ks = short_keys(n * 10, "user:");
    ops = len(ks);
    t0 = time.mono();
    let m = fill(ks);
    sum = len(m);
} else if mode == "str_del" {
    let ks = short_keys(n, "user:");
    let m = fill(ks);
    ops = n / 2;
    t0 = time.mono();
    for i in 0..ops {
        del(m, ks[i * 2]);
    }
    sum = len(m);
} else if mode == "int_hit" {
    let m: map[int]int = {};
    for i in 0..n {
        m[i * 7919 % 1000003] = i;
    }
    let state = [88172645463325252];
    t0 = time.mono();
    for _ in 0..ops {
        let k = (next(state) % n) * 7919 % 1000003;
        if has(m, k) {
            sum += m[k];
        }
    }
} else if mode == "int_put" {
    ops = n * 10;
    t0 = time.mono();
    let m: map[int]int = {};
    for i in 0..ops {
        m[i * 7919] = i;
    }
    sum = len(m);
} else {
    println("unknown mode " + mode);
    exit(2);
}
let ns = (time.mono() - t0) as int;
println("ns_per_op=" + to_str(ns / ops) + " sum=" + to_str(sum));
