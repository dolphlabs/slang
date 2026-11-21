// math/sketch: every sketch against exact answers on fixed data. The
// hashes are fixed, so counts and estimates print exactly; accuracy is
// also checked against each sketch's stated bound.
import "math/sketch";
import "rand";
import "math";

fn within(est: float, truth: float, rel: float) -> bool {
    return math.abs(est - truth) <= rel * truth;
}

// ---- HyperLogLog
let h = sketch.hyperloglog(14);
println(h.count());                              // 0: empty
for i in 0..200000 { h.add_int(i); }
for i in 0..200000 { h.add_int(i); }             // repeats change nothing
let c = h.count();
println(c);
println(within(c as float, 200000.0, 3.0 * 0.0081));
let small = sketch.hyperloglog(12);
for i in 0..100 { small.add_str("user-" + to_str(i)); }
println(small.count());                          // small range: near exact
let a = sketch.hyperloglog(14);
let b = sketch.hyperloglog(14);
for i in 0..60000 { a.add_int(i); }
for i in 40000..100000 { b.add_int(i); }
println(a.merge(b));
println(within(a.count() as float, 100000.0, 3.0 * 0.0081));
println(a.merge(sketch.hyperloglog(10)));        // precision mismatch
let enc = a.encode();
println(len(enc));
let back = sketch.decode_hyperloglog(enc);
if let hb = back { println(hb.count() == a.count()); }
let badh = sketch.decode_hyperloglog(b"\x01\x05");
if let x = badh { println("decoded junk"); } else let e = err_of(badh) { println(e); }
a.clear();
println(a.count());

// ---- CountMin
let cm = sketch.count_min(0.001, 0.01);
println("${cm.width()}x${cm.depth()}");
for i in 0..100000 {
    cm.add_int(i % 1000, 1);                     // 1000 keys, 100 each
}
cm.add_str("hot", 5000);
println(cm.estimate_str("hot") >= 5000);
println(cm.estimate_str("hot") <= 5000 + (0.001 * (cm.total() as float)) as int);
let worst = 0;
for k in 0..1000 {
    let over = cm.estimate_int(k) - 100;
    assert(over >= 0, "count-min underestimated");
    if over > worst { worst = over; }
}
println(worst <= 105);
let cons = sketch.count_min_sized(256, 4).set_conservative(true);
let plain = sketch.count_min_sized(256, 4);
for i in 0..20000 {
    cons.add_int(i % 2000, 1);
    plain.add_int(i % 2000, 1);
}
let cerr = 0;
let perr = 0;
for k in 0..2000 {
    cerr += cons.estimate_int(k) - 10;
    perr += plain.estimate_int(k) - 10;
}
println(cerr <= perr);                           // conservative is tighter
let cm2 = sketch.decode_count_min(cm.encode());
if let c2 = cm2 { println(c2.estimate_str("hot") == cm.estimate_str("hot")); }
println(cm.merge(cm));
println(cm.estimate_str("hot") >= 10000);

// ---- TopK
let tk = sketch.top_k(5);
let r = rand.new(11);
for i in 0..50000 {
    // key j appears with weight about 1/(j+1): a Zipf-like stream
    let j = rand.below(r, 100);
    let k = rand.below(r, j + 1);
    tk.add("k" + to_str(k));
}
let top = tk.top();
println(len(top));
println(top[0].key);
println(top[0].count - top[0].error <= top[0].count);
let tk2 = sketch.top_k(5);
tk2.add_n("k0", 100000);
tk.merge(tk2);
println(tk.top()[0].key);
println((tk.count("k0") ?? -1) >= 100000);
println((tk.count("nope") ?? -1) == -1);

// ---- Bloom
let bf = sketch.bloom(100000, 0.01);
println(bf.size_bytes());
for i in 0..100000 { bf.add_int(i); }
let missing = 0;
for i in 0..100000 {
    if !bf.contains_int(i) { missing += 1; }
}
println(missing);                                // never a false negative
let fp = 0;
for i in 100000..200000 {
    if bf.contains_int(i) { fp += 1; }
}
println(fp < 1500);                              // about 1%
println(math.round_to(bf.fill(), 1));
println(bf.fpp() > 0.005 && bf.fpp() < 0.02);   // the 1% it was sized for
let bf2 = sketch.decode_bloom(bf.encode());
if let b2 = bf2 { println(b2.contains_int(77) && b2.fill() == bf.fill()); }
bf.add_str("x");
println(bf.contains_str("x"));

// ---- Cuckoo
let cf = sketch.cuckoo(10000);
let added = 0;
for i in 0..10000 {
    if cf.add_int(i) { added += 1; }
}
println(added);
let gone = 0;
for i in 0..10000 {
    if !cf.contains_int(i) { gone += 1; }
}
println(gone);
let cfp = 0;
for i in 10000..110000 {
    if cf.contains_int(i) { cfp += 1; }
}
println(cfp < 100);                              // about 0.012% of 100000 is 12
for i in 0..5000 { assert(cf.remove_int(i), "remove"); }
println(cf.count());
let still = 0;
for i in 5000..10000 {
    if cf.contains_int(i) { still += 1; }
}
println(still);
let full = sketch.cuckoo(8);
let ok_n = 0;
for i in 0..64 {
    if full.add_int(i) { ok_n += 1; }
}
let lost = 0;
for i in 0..64 {
    if i < ok_n && !full.contains_int(i) { lost += 1; }
}
println("${ok_n > 0} ${lost}");

// ---- Histogram
let hg = sketch.histogram(60000000, 7);
println(len(hg.buckets([0])));
for v in 1..=100000 { hg.record(v); }
println(hg.count());
println(hg.min());
println(hg.max());
println(hg.mean());
let p50 = hg.quantile(0.5);
let p99 = hg.quantile(0.99);
println(within(p50 as float, 50000.0, 0.008));
println(within(p99 as float, 99000.0, 0.008));
println(hg.quantile(0.0));
println(hg.quantile(1.0));
println(inspect(hg.buckets([10, 1000, 50000, 200000])));
println(math.round_to(hg.rank_of(25000), 2));
let hg2 = sketch.histogram(60000000, 7);
hg2.record_n(70000000, 3);                       // over the range
println(hg2.overflow());
println(hg2.max());
println(hg.merge(hg2));
println(hg.count());
println(hg.merge(sketch.histogram(1000, 7)));
println(inspect(sketch.exponential_bounds(1, 2.0, 6)));
println(inspect(sketch.linear_bounds(10, 5, 4)));
let small_h = sketch.histogram(100, 3);
for v in 0..=100 { small_h.record(v); }
println(small_h.quantile(0.5));

// ---- Reservoir
let keep: [int] = [];
let rs = sketch.reservoir(10, rand.new(5));
for i in 0..100000 {
    if let slot = rs.offer() {
        if slot == len(keep) { push(keep, i); } else { keep[slot] = i; }
    }
}
println(len(keep));
println(rs.seen());
// fairness: over many runs each of 20 items is kept about k/n of the time
let hits: [int] = [];
for i in 0..20 { push(hits, 0); }
let rr = rand.new(9);
for run in 0..20000 {
    let s: [int] = [];
    let res = sketch.reservoir(5, rr);
    for i in 0..20 {
        if let slot = res.offer() {
            if slot == len(s) { push(s, i); } else { s[slot] = i; }
        }
    }
    for x in s { hits[x] += 1; }
}
let fair = true;
for x in hits {
    if !within(x as float, 5000.0, 0.06) { fair = false; }
}
println(fair);
println(sketch.hash_str("abc") == sketch.hash_str("abc"));
println(sketch.hash_bytes(b"abc") != sketch.hash_bytes(b"abd"));
