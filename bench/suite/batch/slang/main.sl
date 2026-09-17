// heavy/batch in slang: fs.pread over newline-aligned byte ranges, one
// task per worker, maps per task merged at the end. See bench/SPEC.md.
import "fs";
import "os";
import "proc";

gc struct Part {
    rows: int,
    // regions are a closed set of two-letter codes: counters indexed by
    // the letters (users and skus stay opaque hash-map keys, per the SPEC)
    region_count: [int],
    region_qty: [int],
    region_revenue: [int],
    users: map[int]int,
    skus: map[str]int,
}

fn new_part() -> Part {
    let rc: [int] = [];
    let rq: [int] = [];
    let rr: [int] = [];
    let k = 0;
    while k < 676 {
        push(rc, 0);
        push(rq, 0);
        push(rr, 0);
        k = k + 1;
    }
    let u: map[int]int = {};
    let s: map[str]int = {};
    return Part { rows: 0, region_count: rc, region_qty: rq, region_revenue: rr, users: u, skus: s };
}

fn add(m: map[str]int, k: str, v: int) {
    if has(m, k) {
        m[k] = m[k] + v;
    } else {
        m[k] = v;
    }
}

fn add_int(m: map[int]int, k: int, v: int) {
    if has(m, k) {
        m[k] = m[k] + v;
    } else {
        m[k] = v;
    }
}

// Parse every complete line in b[0..end) into p.
fn parse(p: Part, b: bytes, end: int) {
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
        let sku = to_str(b[sku_start..i]);
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
        p.region_count[region] = p.region_count[region] + 1;
        p.region_qty[region] = p.region_qty[region] + qty;
        p.region_revenue[region] = p.region_revenue[region] + rev;
        add_int(p.users, user, rev);
        add(p.skus, sku, rev);
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

fn work(path: str, start: int, end: int) -> Part {
    let p = new_part();
    let or = fs.open(path);
    guard let fd = or else { panic("open " + path); }
    let pos = start;
    let carry = b"";
    while pos < end {
        let want = 16777216;
        if end - pos < want { want = end - pos; }
        let rr = fs.pread(fd, pos, want);
        guard let got = rr else let e = err_of(rr) { panic("read: " + e); }
        pos = pos + len(got);
        let block = carry + got;
        let nl = last_newline(block);
        parse(p, block, nl + 1);
        carry = block[nl + 1..];
    }
    fs.close(fd);
    return p;
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

fn ahead_user(ra: int, ua: int, rb: int, ub: int) -> bool {
    return ra > rb || (ra == rb && ua < ub);
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

let path = proc.args()[1];
let sr = os.size(path);
guard let size = sr else let e = err_of(sr) {
    println("size: " + e);
    exit(1);
}
let workers = to_int(proc.getenv("WORKERS") ?? "8") ?? 8;
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
    push(hs, spawn work(path, bounds[w], bounds[w + 1]));
    w = w + 1;
}
let total = new_part();
for h in hs {
    let r = join_wait(h);
    guard let p = r else let e = err_of(r) {
        println("worker: " + e);
        exit(1);
    }
    total.rows = total.rows + p.rows;
    let ri = 0;
    while ri < 676 {
        total.region_count[ri] = total.region_count[ri] + p.region_count[ri];
        total.region_qty[ri] = total.region_qty[ri] + p.region_qty[ri];
        total.region_revenue[ri] = total.region_revenue[ri] + p.region_revenue[ri];
        ri = ri + 1;
    }
    for k, v in p.users { add_int(total.users, k, v); }
    for k, v in p.skus { add(total.skus, k, v); }
}

let top_rev: [int] = [];
let top_user: [int] = [];
for u, v in total.users {
    let n = len(top_rev);
    if n == 100 && !ahead_user(v, u, top_rev[99], top_user[99]) { continue; }
    if n < 100 {
        push(top_rev, v);
        push(top_user, u);
        n = n + 1;
    } else {
        top_rev[99] = v;
        top_user[99] = u;
    }
    let i = n - 1;
    while i > 0 && ahead_user(top_rev[i], top_user[i], top_rev[i - 1], top_user[i - 1]) {
        let tr = top_rev[i];
        let tu = top_user[i];
        top_rev[i] = top_rev[i - 1];
        top_user[i] = top_user[i - 1];
        top_rev[i - 1] = tr;
        top_user[i - 1] = tu;
        i = i - 1;
    }
}

let sku_rev: [int] = [];
let sku_name: [str] = [];
for k, v in total.skus {
    let n = len(sku_rev);
    if n == 10 && !(v > sku_rev[9] || (v == sku_rev[9] && bytes_less(k, sku_name[9]))) { continue; }
    if n < 10 {
        push(sku_rev, v);
        push(sku_name, k);
        n = n + 1;
    } else {
        sku_rev[9] = v;
        sku_name[9] = k;
    }
    let i = n - 1;
    while i > 0 && (sku_rev[i] > sku_rev[i - 1] || (sku_rev[i] == sku_rev[i - 1] && bytes_less(sku_name[i], sku_name[i - 1]))) {
        let tr = sku_rev[i];
        let tn = sku_name[i];
        sku_rev[i] = sku_rev[i - 1];
        sku_name[i] = sku_name[i - 1];
        sku_rev[i - 1] = tr;
        sku_name[i - 1] = tn;
        i = i - 1;
    }
}

let out = "rows=" + to_str(total.rows) + "\n";
let letters = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ";
let c = 0;
while c < 676 {
    if total.region_count[c] > 0 {
        out = out + "region=" + to_str(letters[c / 26..c / 26 + 1]) + to_str(letters[c % 26..c % 26 + 1]) +
              " count=" + to_str(total.region_count[c]) + " qty=" + to_str(total.region_qty[c]) +
              " revenue=" + to_str(total.region_revenue[c]) + "\n";
    }
    c = c + 1;
}
let i = 0;
while i < len(top_rev) {
    out = out + "top_user rank=" + to_str(i + 1) + " user_id=" + to_str(top_user[i]) +
          " revenue=" + to_str(top_rev[i]) + "\n";
    i = i + 1;
}
i = 0;
while i < len(sku_rev) {
    out = out + "top_sku rank=" + to_str(i + 1) + " sku=" + sku_name[i] + " revenue=" +
          to_str(sku_rev[i]) + "\n";
    i = i + 1;
}
print(out);
