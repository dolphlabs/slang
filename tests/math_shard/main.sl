// math/shard: balance, minimal movement and stability of each scheme on
// fixed keys. The hashes are fixed, so assignments print exactly.
import "math/shard";
import "math";

fn spread(counts: [int], expect: float) -> float {
    let worst = 0.0;
    for c in counts {
        worst = math.max(worst, math.abs((c as float) - expect) / expect);
    }
    return worst;
}

// ---- jump
println(shard.jump(0, 1));
println(shard.jump(123456789, 10));
println(shard.jump_str("user-42", 16));
println(shard.jump_int(7, 0));                    // buckets below 1 count as 1
let counts: [int] = [];
for i in 0..10 { push(counts, 0); }
let moved = 0;
for k in 0..100000 {
    let b10 = shard.jump_int(k, 10);
    counts[b10] += 1;
    let b11 = shard.jump_int(k, 11);
    if b11 != b10 {
        assert(b11 == 10, "jump moved a key between old buckets");
        moved += 1;
    }
}
println(spread(counts, 10000.0) < 0.03);
println(math.abs((moved as float) / 100000.0 - 1.0 / 11.0) < 0.005);

// ---- rendezvous
let nodes = ["db-a", "db-b", "db-c", "db-d"];
let r = shard.rendezvous(nodes);
println(r.size());
println(r.node(r.pick_str("user-42") ?? 0));
let rc: [int] = [0, 0, 0, 0];
for k in 0..40000 { rc[r.pick_int(k) ?? 0] += 1; }
println(spread(rc, 10000.0) < 0.04);
// remove db-c: only its keys move
let r3 = shard.rendezvous(["db-a", "db-b", "db-d"]);
let bad = 0;
for k in 0..20000 {
    let before = r.node(r.pick_int(k) ?? 0);
    let after = r3.node(r3.pick_int(k) ?? 0);
    if before != "db-c" && before != after { bad += 1; }
}
println(bad);
let top2 = r.pick_n_str("user-42", 2);
println(len(top2) == 2 && top2[0] == (r.pick_str("user-42") ?? -1) && top2[0] != top2[1]);
println(len(r.pick_n_str("x", 9)));
let w = shard.rendezvous_weighted(["small", "big"], [1.0, 3.0]);
let wc: [int] = [0, 0];
for k in 0..40000 { wc[w.pick_int(k) ?? 0] += 1; }
println(math.abs((wc[1] as float) / 40000.0 - 0.75) < 0.01);
println((shard.rendezvous([]).pick_int(1) ?? -1) == -1);
let z = shard.rendezvous_weighted(["off"], [0.0]);
println((z.pick_int(1) ?? -1) == -1);

// ---- ring
let ring = shard.ring(160);
println(ring.add("cache-1", 1));
ring.add("cache-2", 1);
ring.add("cache-3", 2);
println(ring.points());
let share: map[str]int = {"cache-1": 0, "cache-2": 0, "cache-3": 0};
let before: [str] = [];
for k in 0..40000 {
    let n = ring.get_int(k) ?? "";
    share[n] += 1;
    push(before, n);
}
println(math.abs((share["cache-3"] as float) / 40000.0 - 0.5) < 0.05);
println(ring.remove("cache-2"));
println(ring.remove("cache-2"));
let wrong = 0;
for k in 0..40000 {
    let n = ring.get_int(k) ?? "";
    if before[k] != "cache-2" && n != before[k] { wrong += 1; }
    if n == "cache-2" { wrong += 1; }
}
println(wrong);
println(inspect(ring.nodes()));
let reps = ring.get_n_str("k", 3);
println(len(reps));
println(ring.add("", 1));
println((shard.ring(10).get_str("x") ?? "none") == "none");

// ---- maglev
let m = shard.maglev(["lb-1", "lb-2", "lb-3", "lb-4", "lb-5"], 65537);
println(m.size());
let mc: [int] = [0, 0, 0, 0, 0];
for k in 0..100000 { mc[m.pick_int(k) ?? 0] += 1; }
println(spread(mc, 20000.0) < 0.03);
let m4 = shard.maglev(["lb-1", "lb-2", "lb-3", "lb-5"], 65537);
let churn = 0;
for k in 0..100000 {
    let a = m.node(m.pick_int(k) ?? 0);
    let b = m4.node(m4.pick_int(k) ?? 0);
    if a != "lb-4" && a != b { churn += 1; }
}
println((churn as float) / 100000.0 < 0.05);   // minimal extra movement
println(shard.maglev(["a"], 10).size());        // raised to a prime: 11
println((shard.maglev([], 7).pick_int(3) ?? -1) == -1);
println(shard.hash_str("abc") == shard.hash_str("abc"));
