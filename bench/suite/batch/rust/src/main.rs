// heavy/batch in Rust: memmap2, a scoped thread per core over newline-
// aligned ranges, ahash maps per thread merged at the end. See bench/SPEC.md.
use ahash::AHashMap;
use mimalloc::MiMalloc;
use std::io::Write;

#[global_allocator]
static GLOBAL: MiMalloc = MiMalloc;

const SKU_MAX: usize = 16;
type Sku = ([u8; SKU_MAX], u8);

#[derive(Default, Clone, Copy)]
struct Region {
    count: i64,
    qty: i64,
    revenue: i64,
}

#[derive(Default)]
struct Part {
    rows: i64,
    regions: AHashMap<[u8; 2], Region>,
    users: AHashMap<i64, i64>,
    skus: AHashMap<Sku, i64>,
}

#[inline]
fn parse_int(b: &[u8], mut i: usize) -> (i64, usize) {
    let mut v = 0i64;
    while b[i].is_ascii_digit() {
        v = v * 10 + (b[i] - b'0') as i64;
        i += 1;
    }
    (v, i + 1)
}

fn work(data: &[u8]) -> Part {
    let mut p = Part {
        users: AHashMap::with_capacity_and_hasher(1 << 20, Default::default()),
        skus: AHashMap::with_capacity_and_hasher(1 << 17, Default::default()),
        ..Default::default()
    };
    let (mut i, n) = (0usize, data.len());
    while i < n {
        while data[i] != b',' {
            i += 1;
        }
        let (user, j) = parse_int(data, i + 1);
        i = j;
        let mut key: Sku = ([0; SKU_MAX], 0);
        while data[i] != b',' {
            if (key.1 as usize) < SKU_MAX {
                key.0[key.1 as usize] = data[i];
                key.1 += 1;
            }
            i += 1;
        }
        let (qty, j) = parse_int(data, i + 1);
        let (price, j) = parse_int(data, j);
        let code = [data[j], data[j + 1]];
        i = j + 3;
        let rev = qty * price;
        let r = p.regions.entry(code).or_default();
        r.count += 1;
        r.qty += qty;
        r.revenue += rev;
        p.rows += 1;
        *p.users.entry(user).or_insert(0) += rev;
        *p.skus.entry(key).or_insert(0) += rev;
    }
    p
}

fn main() {
    let path = std::env::args().nth(1).expect("usage: batch <file.csv>");
    let file = std::fs::File::open(&path).expect("open");
    let size = file.metadata().expect("stat").len() as usize;
    let map = if size > 0 { Some(unsafe { memmap2::Mmap::map(&file).expect("mmap") }) } else { None };
    let data: &[u8] = map.as_deref().unwrap_or(&[]);
    #[cfg(unix)]
    if let Some(m) = &map {
        let _ = m.advise(memmap2::Advice::Sequential);
    }

    let mut workers = std::env::var("WORKERS").ok().and_then(|v| v.parse().ok()).filter(|&v: &usize| v > 0)
        .unwrap_or_else(|| std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1));
    workers = workers.min(size / (1 << 16) + 1);

    let mut ranges = Vec::with_capacity(workers);
    let mut start = 0usize;
    for w in 0..workers {
        let mut end = if w == workers - 1 { size } else { (size / workers * (w + 1)).max(start) };
        while end < size && data[end - 1] != b'\n' {
            end += 1;
        }
        ranges.push((start, end));
        start = end;
    }
    let mut parts: Vec<Part> = std::thread::scope(|s| {
        let handles: Vec<_> = ranges.iter().map(|&(a, b)| s.spawn(move || work(&data[a..b]))).collect();
        handles.into_iter().map(|h| h.join().unwrap()).collect()
    });

    let big = (0..parts.len()).max_by_key(|&i| parts[i].users.len()).unwrap_or(0);
    let mut main = std::mem::take(&mut parts[big]);
    for (i, p) in parts.into_iter().enumerate() {
        if i == big {
            continue;
        }
        main.rows += p.rows;
        for (code, r) in p.regions {
            let t = main.regions.entry(code).or_default();
            t.count += r.count;
            t.qty += r.qty;
            t.revenue += r.revenue;
        }
        for (u, v) in p.users {
            *main.users.entry(u).or_insert(0) += v;
        }
        for (k, v) in p.skus {
            *main.skus.entry(k).or_insert(0) += v;
        }
    }

    let mut top: Vec<(i64, i64)> = Vec::with_capacity(101); // (revenue, user)
    let ahead = |a: &(i64, i64), b: &(i64, i64)| a.0 > b.0 || (a.0 == b.0 && a.1 < b.1);
    for (&u, &v) in &main.users {
        let c = (v, u);
        if top.len() == 100 && !ahead(&c, &top[99]) {
            continue;
        }
        let at = top.iter().position(|t| ahead(&c, t)).unwrap_or(top.len());
        top.insert(at, c);
        top.truncate(100);
    }
    let mut skus: Vec<(&Sku, &i64)> = main.skus.iter().collect();
    skus.sort_unstable_by(|a, b| b.1.cmp(a.1).then_with(|| a.0 .0[..a.0 .1 as usize].cmp(&b.0 .0[..b.0 .1 as usize])));
    let mut codes: Vec<_> = main.regions.iter().collect();
    codes.sort_by_key(|(c, _)| **c);

    let mut out = Vec::with_capacity(16 * 1024);
    writeln!(out, "rows={}", main.rows).unwrap();
    for (c, r) in codes {
        writeln!(out, "region={}{} count={} qty={} revenue={}", c[0] as char, c[1] as char, r.count, r.qty, r.revenue).unwrap();
    }
    for (i, (v, u)) in top.iter().enumerate() {
        writeln!(out, "top_user rank={} user_id={} revenue={}", i + 1, u, v).unwrap();
    }
    for (i, (k, v)) in skus.iter().take(10).enumerate() {
        writeln!(out, "top_sku rank={} sku={} revenue={}", i + 1, std::str::from_utf8(&k.0[..k.1 as usize]).unwrap_or("?"), v).unwrap();
    }
    std::io::stdout().write_all(&out).unwrap();
}
