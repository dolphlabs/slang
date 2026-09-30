// del on a map used to empty the key's slot outright. The table probes
// linearly and stops at the first empty slot, so every key stored further
// along the same probe run became unreachable: has() said no, deleting it
// did nothing, and assigning it stored it a second time. Deleting 300 of
// 3000 string keys lost 240 of the rest and 174 updates became duplicates.
//
// Seeded pseudo-random inserts, updates and deletes, checked against a
// plain model after every round: every live key found with its value,
// every deleted key gone, the size right, and iteration visiting each live
// key once, in insertion order. String keys and int keys take different
// hashing paths, so both run.

gc struct Rng {
    s: int,
}

fn next_rand(r: Rng) -> int {
    r.s = (r.s * 1103515245 + 12345) % 2147483648;
    return r.s;
}

fn fail(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn key_of(i: int) -> str {
    return "k" + to_str(i);
}

// The model: for each key id, whether it is live, its value, and the
// insertion order of live keys.
fn check_str(m: map[str]int, live: [bool], vals: [int], order: [int],
             what: str) {
    let n = 0;
    let i = 0;
    while i < len(live) {
        let k = key_of(i);
        if live[i] {
            n = n + 1;
            if !has(m, k) { fail(what + ": live key " + k + " not found"); }
            if m[k] != vals[i] { fail(what + ": wrong value for " + k); }
        } else if has(m, k) {
            fail(what + ": deleted key " + k + " still there");
        }
        i = i + 1;
    }
    if len(m) != n {
        fail(what + ": size " + to_str(len(m)) + " want " + to_str(n));
    }
    // A key deleted and inserted again goes to the end: only its last
    // insertion counts.
    let last: [int] = [];
    i = 0;
    while i < len(live) {
        push(last, -1);
        i = i + 1;
    }
    let p = 0;
    while p < len(order) {
        last[order[p]] = p;
        p = p + 1;
    }
    let want: [int] = [];
    p = 0;
    while p < len(order) {
        let id = order[p];
        if live[id] && last[id] == p { push(want, id); }
        p = p + 1;
    }
    let at = 0;
    for k, v in m {
        if at >= len(want) { fail(what + ": iteration visits too many"); }
        if k != key_of(want[at]) {
            fail(what + ": iteration order at " + to_str(at));
        }
        at = at + 1;
    }
    if at != len(want) { fail(what + ": iteration visits too few"); }
}

fn str_keys(r: Rng) {
    let ids = 4000;
    let m: map[str]int = {};
    let live: [bool] = [];
    let vals: [int] = [];
    let order: [int] = [];
    let i = 0;
    while i < ids {
        push(live, false);
        push(vals, 0);
        i = i + 1;
    }
    let round = 0;
    while round < 40 {
        let op = 0;
        while op < 500 {
            let id = next_rand(r) % ids;
            let what = next_rand(r) % 3;
            if what == 0 {
                del(m, key_of(id));
                live[id] = false;
            } else {
                let v = next_rand(r) % 100000;
                if !live[id] {
                    push(order, id);
                }
                m[key_of(id)] = v;
                live[id] = true;
                vals[id] = v;
            }
            op = op + 1;
        }
        check_str(m, live, vals, order, "str round " + to_str(round));
        round = round + 1;
    }
    // delete everything, then the map must be empty and reusable
    i = 0;
    while i < ids {
        del(m, key_of(i));
        live[i] = false;
        i = i + 1;
    }
    check_str(m, live, vals, order, "str emptied");
    m[key_of(7)] = 7;
    if len(m) != 1 || m[key_of(7)] != 7 { fail("str reuse"); }
    println("str_keys");
}

fn int_keys(r: Rng) {
    let ids = 3000;
    let m: map[int]int = {};
    let live: [bool] = [];
    let i = 0;
    while i < ids {
        push(live, false);
        i = i + 1;
    }
    let round = 0;
    while round < 40 {
        let op = 0;
        while op < 400 {
            let id = next_rand(r) % ids;
            if next_rand(r) % 2 == 0 {
                del(m, id * 7919);
                live[id] = false;
            } else {
                m[id * 7919] = id;
                live[id] = true;
            }
            op = op + 1;
        }
        let n = 0;
        i = 0;
        while i < ids {
            if live[i] {
                n = n + 1;
                if !has(m, i * 7919) { fail("int live key " + to_str(i)); }
                if m[i * 7919] != i { fail("int value " + to_str(i)); }
            } else if has(m, i * 7919) {
                fail("int deleted key " + to_str(i));
            }
            i = i + 1;
        }
        if len(m) != n { fail("int size"); }
        round = round + 1;
    }
    println("int_keys");
}

let r = Rng { s: 12345 };
str_keys(r);
int_keys(r);
println("done");
