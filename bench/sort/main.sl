// The sort package against Go's, scene by scene, on byte-identical
// data.
//
// Every scene: build the inputs once, then time 5 per-round sorts over
// a fresh copy of the source list, and verify the sorted result
// outside the measured interval. Each round re-sorts its own copy, so
// no round sees its input already ordered. Report per scene:
//
//     scene,NAME,n,MEDIAN_MS
//
// bench/sort/run.sh alternates the two binaries ABBA and prints each
// scene's median over three full runs of both programs; peak memory
// comes from /usr/bin/time -l the same way for both.
//
// Inputs are at-index generative, not streamed: element i reads
// mix(seed + 3*i + k) for the scene's k, where mix is a two-step
// Lehmer walk with a bounded multiplier followed by a square-and-mod
// step. The square is what makes the small moduli usable: a purely
// multiplicative chain mod a prime stays LINEAR in the index, so
// values mod 4 or mod 6 repeat with short periods and the
// duplicate-heavy scenes degenerate; squaring breaks that (verified:
// no period up to 64, bucket counts within 0.4% of uniform, for the
// language-agnostic check in bench/sort/README.md). No overflow
// question: the walk lives below 2^31, so the square is below 2^62.
// The Go counterpart in bench/sort/go uses the same mix and the same
// k per scene, so the two programs hold byte-identical inputs.
import "sort";
import "strings";
import "time";

// rounds() rather than a top-level binding: only statements see those
fn rounds() -> int {
    return 5;
}

fn lcf(x: int) -> int {
    let q = (x * 48271) % 2147483647;
    return (q * 48271) % 2147483647;
}

// the square-and-mod step that keeps small moduli honest; see the
// header note for why a pure chain mod a prime degenerates
fn mix(x: int) -> int {
    let t = lcf(x);
    return (t * t) % 2147483647;
}

struct Row {
    id: int,
    tag: str,
    oi: int,
}

fn id_of(r: Row) -> int {
    return r.id;
}

fn tag_of(r: Row) -> str {
    return r.tag;
}

fn gen_ints(n: int) -> [int] {
    let out: [int] = [];
    let i = 0;
    while i < n {
        push(out, mix(12345 + 3 * i) % 1000003 - 500000);
        i += 1;
    }
    return out;
}

fn gen_ints_eq4(n: int) -> [int] {
    let out: [int] = [];
    let i = 0;
    while i < n {
        push(out, mix(12345 + 3 * i) % 4);
        i += 1;
    }
    return out;
}

fn gen_floats(n: int) -> [float] {
    let out: [float] = [];
    let i = 0;
    while i < n {
        push(out, (mix(12345 + 3 * i) % 1000003 - 500000) / 1000.0);
        i += 1;
    }
    return out;
}

// length (h%6)+4 of lowercase letters; the Go counterpart shares the
// grammar and the state chain
fn gen_str_at(i: int) -> str {
    let ln = mix(12345 + 3 * i) % 6 + 4;
    let b = strings.bytes_zero(ln);
    let k = 0;
    while k < ln {
        b[k] = mix(12345 + 3 * i + 1 + k) % 26 + 97;
        k += 1;
    }
    return strings.from_bytes(b, 0, ln);
}

// ---------------------------------------------------------------- //
// Drivers: fresh copy, timed sort, verification off the clock        //
// ---------------------------------------------------------------- //

fn report(name: str, n: int, ms: float) {
    println("scene," + name + "," + to_str(n) + "," + to_str(ms));
}

// median: sorts the round timings in place and reads the middle
fn median_of(times: [float]) -> float {
    sort.floats(times);
    return times[len(times) / 2];
}

fn ms_ints(name: str, src: [int]) {
    let n = len(src);
    let times: [float] = [];
    let r = 0;
    while r < rounds() {
        let work = src[0..n];
        let t0 = time.mono();
        sort.ints(work);
        let ns = (time.mono() - t0) as int;
        push(times, ns as float / 1000000.0);
        let c = 1;
        while c < n {
            assert(work[c - 1] <= work[c]);
            c += 1;
        }
        r += 1;
    }
    report(name, n, median_of(times));
}

fn ms_floats(name: str, src: [float]) {
    let n = len(src);
    let times: [float] = [];
    let r = 0;
    while r < rounds() {
        let work = src[0..n];
        let t0 = time.mono();
        sort.floats(work);
        let ns = (time.mono() - t0) as int;
        push(times, ns as float / 1000000.0);
        let c = 1;
        while c < n {
            assert(!(work[c] < work[c - 1]));
            c += 1;
        }
        r += 1;
    }
    report(name, n, median_of(times));
}

fn ms_strs(name: str, src: [str]) {
    let n = len(src);
    let times: [float] = [];
    let r = 0;
    while r < rounds() {
        let work = src[0..n];
        let t0 = time.mono();
        sort.strings(work);
        let ns = (time.mono() - t0) as int;
        push(times, ns as float / 1000000.0);
        let c = 1;
        while c < n {
            assert(work[c - 1] <= work[c]);
            c += 1;
        }
        r += 1;
    }
    report(name, n, median_of(times));
}

// sort.by over an int key
fn ms_by_int(name: str, src: [Row]) {
    let n = len(src);
    let times: [float] = [];
    let r = 0;
    while r < rounds() {
        let work = src[0..n];
        let t0 = time.mono();
        sort.by(work, id_of);
        let ns = (time.mono() - t0) as int;
        push(times, ns as float / 1000000.0);
        let c = 1;
        while c < n {
            assert(!(work[c].id < work[c - 1].id));
            c += 1;
        }
        r += 1;
    }
    report(name, n, median_of(times));
}

// sort.by over a str key (unstable, verify ascending)
fn ms_by_str(name: str, src: [Row]) {
    let n = len(src);
    let times: [float] = [];
    let r = 0;
    while r < rounds() {
        let work = src[0..n];
        let t0 = time.mono();
        sort.by(work, tag_of);
        let ns = (time.mono() - t0) as int;
        push(times, ns as float / 1000000.0);
        let c = 1;
        while c < n {
            assert(!(work[c].tag < work[c - 1].tag));
            c += 1;
        }
        r += 1;
    }
    report(name, n, median_of(times));
}

// sort.by_stable over the six tagged groups: ascending tag, within
// each tag oi steps up exactly in the original order
fn ms_by_stable(name: str, src: [Row]) {
    let n = len(src);
    let times: [float] = [];
    let r = 0;
    while r < rounds() {
        let work = src[0..n];
        let t0 = time.mono();
        sort.by_stable(work, tag_of);
        let ns = (time.mono() - t0) as int;
        push(times, ns as float / 1000000.0);
        let c = 1;
        while c < n {
            assert(!(work[c].tag < work[c - 1].tag));
            if work[c].tag == work[c - 1].tag {
                assert(work[c].oi > work[c - 1].oi);
            }
            c += 1;
        }
        r += 1;
    }
    report(name, n, median_of(times));
}

// ---------------------------------------------------------------- //
// Scenes                                                             //
// ---------------------------------------------------------------- //

ms_ints("ints_random_1k", gen_ints(1000));
ms_ints("ints_random_100k", gen_ints(100000));
ms_ints("ints_random_1m", gen_ints(1000000));

// sorted and strictly descending: the two shapes the adaptive pass
// takes over, so the entry scan answers these in O(n)
let asc: [int] = [];
let i = 0;
while i < 1000000 {
    push(asc, i * 11 - 5000);
    i += 1;
}
ms_ints("ints_sorted_1m", asc);

let de: [int] = [];
i = 0;
while i < 1000000 {
    push(de, 499999 - i);
    i += 1;
}
ms_ints("ints_desc_1m", de);

// four distinct values, shuffled: the duplicate-heavy shape
ms_ints("ints_equal_1m", gen_ints_eq4(1000000));

ms_floats("floats_random_1m", gen_floats(1000000));

let strs: [str] = [];
let s = 0;
while s < 100000 {
    push(strs, gen_str_at(s));
    s += 1;
}
ms_strs("strings_random_100k", strs);

let r1: [Row] = [];
i = 0;
while i < 250000 {
    push(r1, Row { id: (mix(12345 + 3 * i) % 1000003 - 500000) * 1000,
                   tag: "", oi: i });
    i += 1;
}
ms_by_int("by_int_250k", r1);

let r2: [Row] = [];
i = 0;
while i < 250000 {
    push(r2, Row { id: i * 11, tag: "", oi: i });
    i += 1;
}
ms_by_int("by_int_sorted_250k", r2);

let r3: [Row] = [];
i = 0;
while i < 100000 {
    push(r3, Row { id: 0, tag: "g" + to_str(mix(12345 + 3 * i + 1) % 6),
                   oi: i });
    i += 1;
}
ms_by_str("by_str_100k", r3);
ms_by_stable("by_stable_100k", r3);
