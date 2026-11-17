// The slang side of bench/cache/run.sh.
//
//     main single|parallel|fill
//
// single: 1M operations, 90% get / 10% put, keys drawn from a skewed
// distribution over 100k keys, in a 10k-entry cache. parallel: the same
// mix, 8 tasks of 500k operations. fill: 1M entries, then RSS is read by
// the runner. Keys are built beforehand; the draws are an xorshift both
// sides share.

import "cache";
import "proc";
import "time";

fn keys(n: int) -> [str] {
    let ks: [str] = [];
    for i in 0..n {
        push(ks, "user:" + to_str(i * 7919 % 1000003));
    }
    return ks;
}

// xorshift64, then a skew: the square of a uniform draw favours low ranks
fn draw(state: [int], n: int) -> int {
    let x = state[0];
    x = x ^ (x << 13);
    x = x ^ ((x >> 7) & 144115188075855871);
    x = x ^ (x << 17);
    state[0] = x;
    let u = (x & 1048575) as float / 1048576.0;
    return (u * u * n as float) as int;
}

fn work(c: cache.Cache[int], ks: [str], ops: int, seed: int) -> int {
    let state = [seed];
    let hits = 0;
    for i in 0..ops {
        let k = draw(state, len(ks));
        if i % 10 == 0 {
            cache.put(c, ks[k], k);
        } else if let _v = cache.get(c, ks[k]) {
            hits += 1;
        }
    }
    return hits;
}

fn make(max: int) -> cache.Cache[int] {
    let o = cache.options();
    o.max_entries = max;
    let r: result[cache.Cache[int], str] = cache.new(o);
    guard let c = r else let e = err_of(r) { panic(e); }
    return c;
}

let mode = proc.args()[1];
if mode == "fill" {
    let ks = keys(1000000);
    let c = make(1000000);
    for i in 0..1000000 {
        cache.put(c, ks[i], i);
    }
    println("entries=" + to_str(cache.len_of(c)));
} else {
    let ks = keys(100000);
    let c = make(10000);
    let tasks = 1;
    let ops = 1000000;
    if mode == "parallel" {
        tasks = 8;
        ops = 500000;
    }
    let t0 = time.mono();
    let hits = 0;
    if tasks == 1 {
        hits = work(c, ks, ops, 88172645463325252);
    } else {
        let hs: [join[int]] = [];
        for t in 0..tasks {
            push(hs, spawn work(c, ks, ops, 88172645463325252 + t * 1000003));
        }
        for h in hs {
            hits += join_wait(h) ?? 0;
        }
    }
    let ns = (time.mono() - t0) as int;
    let total = tasks * ops;
    println("ns_per_op=" + to_str(ns / total) + " hit_rate=" + to_str(hits * 1000 / (total * 9 / 10)) + "/1000");
}
