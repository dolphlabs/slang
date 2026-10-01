// heavy/batch in slang: fs.pread over newline-aligned byte ranges, one
// task per worker, per-task tables merged in parallel at the end. See
// bench/SPEC.md.
import "fs";
import "os";
import "proc";
import "strings";

// Users and skus go in open-addressing tables (the SPEC allows a hand-
// written one): a row costs one probe and no allocation. Each table is one
// flat int list, a slot's fields side by side, so a probe touches one
// cache line, and an int list holds nothing for the collector to chase.

// A user slot is [id, revenue]; id 0 marks it empty. A real user 0 is
// counted in `zero_rev` instead, so every int is still a valid key.
gc struct UserTable {
    mask: int,
    count: int,
    kv: [int],
    has_zero: bool,
    zero_rev: int,
}

// A sku slot is [bytes 0..8, bytes 8..16, length, revenue, name index]:
// a sku of up to 16 bytes is its bytes packed into two ints, so a row
// allocates nothing. Length 0 marks an empty slot; an empty or longer sku
// goes through `long`, keyed by its string. Slots are 5 ints wide.

gc struct SkuTable {
    mask: int,
    count: int,
    kv: [int],
    name: [str],
    long: map[str]int,
    long_rev: [int],
}

gc struct Part {
    rows: int,
    // regions are a closed set of two-letter codes: counters indexed by
    // the letters (users and skus stay opaque hash-map keys, per the SPEC)
    region_count: [int],
    region_qty: [int],
    region_revenue: [int],
    // users are split into shards by hash, so the merge runs one task
    // per shard
    users: [UserTable],
    skus: SkuTable,
}

fn filled(n: int, v: int) -> [int] {
    let s: [int] = [];
    let i = 0;
    while i < n {
        push(s, v);
        i = i + 1;
    }
    return s;
}

fn new_users(cap: int) -> UserTable {
    return UserTable { mask: cap - 1, count: 0, kv: filled(cap * 2, 0), has_zero: false, zero_rev: 0 };
}

fn new_skus(cap: int) -> SkuTable {
    let n: [str] = [];
    let l: map[str]int = {};
    let lr: [int] = [];
    return SkuTable { mask: cap - 1, count: 0, kv: filled(cap * 5, 0), name: n, long: l, long_rev: lr };
}

fn new_part(shards: int) -> Part {
    let us: [UserTable] = [];
    let s = 0;
    while s < shards {
        push(us, new_users(16384));
        s = s + 1;
    }
    return Part { rows: 0, region_count: filled(676, 0), region_qty: filled(676, 0),
                  region_revenue: filled(676, 0), users: us, skus: new_skus(16384) };
}

// splitmix64's finalizer; the masks make >> logical on a signed int.
fn mix(x: int) -> int {
    let h = (x ^ ((x >> 30) & 17179869183)) * -4658895280553007687;
    h = (h ^ ((h >> 27) & 137438953471)) * -7723592293110705685;
    return h ^ ((h >> 31) & 8589934591);
}

// The shard a user hashes to, from bits the slot index does not use.
fn shard_of(h: int, shards: int) -> int {
    return ((h >> 40) & 16777215) % shards;
}

fn user_grow(t: UserTable) {
    let old = t.kv;
    let cap = (t.mask + 1) * 2;
    t.mask = cap - 1;
    t.kv = filled(cap * 2, 0);
    let i = 0;
    while i < len(old) {
        let id = old[i];
        if id != 0 {
            let j = mix(id) & t.mask;
            while t.kv[j * 2] != 0 { j = (j + 1) & t.mask; }
            t.kv[j * 2] = id;
            t.kv[j * 2 + 1] = old[i + 1];
        }
        i = i + 2;
    }
}

fn add_user(t: UserTable, id: int, h: int, rev: int) {
    if id == 0 {
        t.has_zero = true;
        t.zero_rev += rev;
        return;
    }
    let j = h & t.mask;
    while true {
        let k = t.kv[j * 2];
        if k == id {
            t.kv[j * 2 + 1] += rev;
            return;
        }
        if k == 0 {
            t.kv[j * 2] = id;
            t.kv[j * 2 + 1] = rev;
            t.count = t.count + 1;
            // at most half full, so a probe stays short
            if t.count * 2 > t.mask { user_grow(t); }
            return;
        }
        j = (j + 1) & t.mask;
    }
}

fn sku_hash(a: int, c: int, n: int) -> int {
    return mix(a ^ mix(c + n));
}

fn sku_grow(t: SkuTable) {
    let old = t.kv;
    let cap = (t.mask + 1) * 2;
    t.mask = cap - 1;
    t.kv = filled(cap * 5, 0);
    let i = 0;
    while i < len(old) {
        if old[i + 2] != 0 {
            let j = sku_hash(old[i], old[i + 1], old[i + 2]) & t.mask;
            while t.kv[j * 5 + 2] != 0 { j = (j + 1) & t.mask; }
            let o = j * 5;
            t.kv[o] = old[i];
            t.kv[o + 1] = old[i + 1];
            t.kv[o + 2] = old[i + 2];
            t.kv[o + 3] = old[i + 3];
            t.kv[o + 4] = old[i + 4];
        }
        i = i + 5;
    }
}

fn add_long_sku(t: SkuTable, k: str, rev: int) {
    if has(t.long, k) {
        t.long_rev[t.long[k]] += rev;
    } else {
        t.long[k] = len(t.long_rev);
        push(t.long_rev, rev);
    }
}

fn add_sku(t: SkuTable, b: bytes, s: int, end: int, rev: int) {
    let n = end - s;
    if n == 0 || n > 16 {
        add_long_sku(t, strings.from_bytes(b, s, end), rev);
        return;
    }
    let a = 0;
    let c = 0;
    let i = 0;
    while i < n && i < 8 {
        a = a | ((b[s + i] as int) << (i * 8));
        i = i + 1;
    }
    while i < n {
        c = c | ((b[s + i] as int) << ((i - 8) * 8));
        i = i + 1;
    }
    let j = sku_hash(a, c, n) & t.mask;
    while true {
        let o = j * 5;
        let l = t.kv[o + 2];
        if l == n && t.kv[o] == a && t.kv[o + 1] == c {
            t.kv[o + 3] += rev;
            return;
        }
        if l == 0 {
            t.kv[o] = a;
            t.kv[o + 1] = c;
            t.kv[o + 2] = n;
            t.kv[o + 3] = rev;
            t.kv[o + 4] = len(t.name);
            push(t.name, strings.from_bytes(b, s, end));
            t.count = t.count + 1;
            if t.count * 2 > t.mask { sku_grow(t); }
            return;
        }
        j = (j + 1) & t.mask;
    }
}

// Parse every complete line in b[0..end) into p.
fn parse(p: Part, b: bytes, end: int) {
    let shards = len(p.users);
    let i = 0;
    while i < end {
        while b[i] != 44 { i = i + 1; }
        i = i + 1;
        let user = 0;
        while b[i] != 44 {
            user = user * 10 + (b[i] - 48);
            i = i + 1;
        }
        i = i + 1;
        let sku_start = i;
        while b[i] != 44 { i = i + 1; }
        let sku_end = i;
        i = i + 1;
        let qty = 0;
        while b[i] != 44 {
            qty = qty * 10 + (b[i] - 48);
            i = i + 1;
        }
        i = i + 1;
        let price = 0;
        while b[i] != 44 {
            price = price * 10 + (b[i] - 48);
            i = i + 1;
        }
        i = i + 1;
        let region = (b[i] - 65) * 26 + (b[i + 1] - 65);
        i = i + 3;
        let rev = qty * price;
        p.region_count[region] += 1;
        p.region_qty[region] += qty;
        p.region_revenue[region] += rev;
        let h = mix(user);
        add_user(p.users[shard_of(h, shards)], user, h, rev);
        add_sku(p.skus, b, sku_start, sku_end, rev);
        p.rows = p.rows + 1;
    }
}

fn last_newline(b: bytes) -> int {
    let i = len(b) - 1;
    while i >= 0 {
        if b[i] == 10 { return i; }
        i = i - 1;
    }
    return -1;
}

fn work(path: str, start: int, end: int, shards: int) -> Part {
    let p = new_part(shards);
    let or = fs.open(path);
    guard let fd = or else { panic("open " + path); }
    let pos = start;
    while pos < end {
        let want = 16777216;
        if end - pos < want { want = end - pos; }
        let rr = fs.pread(fd, pos, want);
        guard let got = rr else let e = err_of(rr) { panic("read: " + e); }
        if len(got) == 0 { panic("read: unexpected end of " + path); }
        // Ranges end on a newline, so the last chunk is whole; any other
        // chunk ends mid-line, and the next read starts again at that line.
        let nl = last_newline(got);
        if nl < 0 { panic("read: a line longer than the chunk in " + path); }
        parse(p, got, nl + 1);
        pos = pos + nl + 1;
    }
    fs.close(fd);
    return p;
}

// Fold shard `s` of every part into the first part's shard `s`.
fn merge_shard(parts: [Part], s: int) -> bool {
    let into = parts[0].users[s];
    let w = 1;
    while w < len(parts) {
        let from = parts[w].users[s];
        let i = 0;
        while i < len(from.kv) {
            let id = from.kv[i];
            if id != 0 { add_user(into, id, mix(id), from.kv[i + 1]); }
            i = i + 2;
        }
        if from.has_zero { add_user(into, 0, 0, from.zero_rev); }
        w = w + 1;
    }
    return true;
}

// The first byte after the newline at or after `at` (or `size`).
fn align(fd: i32, at: int, size: int) -> int {
    if at <= 0 { return 0; }
    let pos = at - 1;
    while pos < size {
        let rr = fs.pread(fd, pos, 4096);
        guard let got = rr else { return size; }
        let i = 0;
        while i < len(got) {
            if got[i] == 10 { return pos + i + 1; }
            i = i + 1;
        }
        pos = pos + len(got);
    }
    return size;
}

fn bytes_less(a: str, b: str) -> bool {
    let x = to_bytes(a);
    let y = to_bytes(b);
    let i = 0;
    while i < len(x) && i < len(y) {
        if x[i] != y[i] { return x[i] < y[i]; }
        i = i + 1;
    }
    return len(x) < len(y);
}

// Top 100 users, revenue desc then id asc, kept sorted by insertion.
gc struct TopUsers {
    rev: [int],
    id: [int],
}

fn ahead_user(ra: int, ua: int, rb: int, ub: int) -> bool {
    return ra > rb || (ra == rb && ua < ub);
}

fn offer_user(t: TopUsers, u: int, v: int) {
    let n = len(t.rev);
    if n == 100 && !ahead_user(v, u, t.rev[99], t.id[99]) { return; }
    if n < 100 {
        push(t.rev, v);
        push(t.id, u);
        n = n + 1;
    } else {
        t.rev[99] = v;
        t.id[99] = u;
    }
    let i = n - 1;
    while i > 0 && ahead_user(t.rev[i], t.id[i], t.rev[i - 1], t.id[i - 1]) {
        let tr = t.rev[i];
        let tu = t.id[i];
        t.rev[i] = t.rev[i - 1];
        t.id[i] = t.id[i - 1];
        t.rev[i - 1] = tr;
        t.id[i - 1] = tu;
        i = i - 1;
    }
}

// Top 10 skus, revenue desc then name asc (byte order).
gc struct TopSkus {
    rev: [int],
    name: [str],
}

fn offer_sku(t: TopSkus, k: str, v: int) {
    let n = len(t.rev);
    if n == 10 && !(v > t.rev[9] || (v == t.rev[9] && bytes_less(k, t.name[9]))) { return; }
    if n < 10 {
        push(t.rev, v);
        push(t.name, k);
        n = n + 1;
    } else {
        t.rev[9] = v;
        t.name[9] = k;
    }
    let i = n - 1;
    while i > 0 && (t.rev[i] > t.rev[i - 1] || (t.rev[i] == t.rev[i - 1] && bytes_less(t.name[i], t.name[i - 1]))) {
        let tr = t.rev[i];
        let tn = t.name[i];
        t.rev[i] = t.rev[i - 1];
        t.name[i] = t.name[i - 1];
        t.rev[i - 1] = tr;
        t.name[i - 1] = tn;
        i = i - 1;
    }
}

let path = proc.args()[1];
let sr = os.size(path);
guard let size = sr else let e = err_of(sr) {
    println("size: " + e);
    exit(1);
}
let workers = to_int(proc.getenv("WORKERS") ?? "8") ?? 8;
if workers < 1 { workers = 1; }
if workers > size / 65536 + 1 { workers = size / 65536 + 1; }
let or = fs.open(path);
guard let fd = or else { exit(1); }
let bounds: [int] = [0];
let w = 1;
while w < workers {
    push(bounds, align(fd, size / workers * w, size));
    w = w + 1;
}
push(bounds, size);
fs.close(fd);

let hs: [join[Part]] = [];
w = 0;
while w < workers {
    push(hs, spawn work(path, bounds[w], bounds[w + 1], workers));
    w = w + 1;
}
let parts: [Part] = [];
for h in hs {
    let r = join_wait(h);
    guard let p = r else let e = err_of(r) {
        println("worker: " + e);
        exit(1);
    }
    push(parts, p);
}

let merges: [join[bool]] = [];
let s = 0;
while s < workers {
    push(merges, spawn merge_shard(parts, s));
    s = s + 1;
}
for m in merges {
    let r = join_wait(m);
    guard let _ok = r else let e = err_of(r) {
        println("merge: " + e);
        exit(1);
    }
}

let total = parts[0];
let rows = 0;
let region_count = filled(676, 0);
let region_qty = filled(676, 0);
let region_revenue = filled(676, 0);
let skus = new_skus(16384);
for p in parts {
    rows = rows + p.rows;
    let ri = 0;
    while ri < 676 {
        region_count[ri] += p.region_count[ri];
        region_qty[ri] += p.region_qty[ri];
        region_revenue[ri] += p.region_revenue[ri];
        ri = ri + 1;
    }
    let i = 0;
    while i < len(p.skus.kv) {
        if p.skus.kv[i + 2] != 0 {
            let nb = to_bytes(p.skus.name[p.skus.kv[i + 4]]);
            add_sku(skus, nb, 0, len(nb), p.skus.kv[i + 3]);
        }
        i = i + 5;
    }
    for k, v in p.skus.long {
        add_long_sku(skus, k, p.skus.long_rev[v]);
    }
}

let top_users = TopUsers { rev: [], id: [] };
for t in total.users {
    let i = 0;
    while i < len(t.kv) {
        if t.kv[i] != 0 { offer_user(top_users, t.kv[i], t.kv[i + 1]); }
        i = i + 2;
    }
    if t.has_zero { offer_user(top_users, 0, t.zero_rev); }
}

let top_skus = TopSkus { rev: [], name: [] };
let i = 0;
while i < len(skus.kv) {
    if skus.kv[i + 2] != 0 { offer_sku(top_skus, skus.name[skus.kv[i + 4]], skus.kv[i + 3]); }
    i = i + 5;
}
for k, v in skus.long {
    offer_sku(top_skus, k, skus.long_rev[v]);
}

let out = "rows=" + to_str(rows) + "\n";
let letters = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ";
let c = 0;
while c < 676 {
    if region_count[c] > 0 {
        out = out + "region=" + to_str(letters[c / 26..c / 26 + 1]) + to_str(letters[c % 26..c % 26 + 1]) +
              " count=" + to_str(region_count[c]) + " qty=" + to_str(region_qty[c]) +
              " revenue=" + to_str(region_revenue[c]) + "\n";
    }
    c = c + 1;
}
i = 0;
while i < len(top_users.rev) {
    out = out + "top_user rank=" + to_str(i + 1) + " user_id=" + to_str(top_users.id[i]) +
          " revenue=" + to_str(top_users.rev[i]) + "\n";
    i = i + 1;
}
i = 0;
while i < len(top_skus.rev) {
    out = out + "top_sku rank=" + to_str(i + 1) + " sku=" + top_skus.name[i] + " revenue=" +
          to_str(top_skus.rev[i]) + "\n";
    i = i + 1;
}
print(out);
