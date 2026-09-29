// Every `b""` evaluates to one shared static empty bytes rather than two
// fresh allocations (runtime sl_bytes_empty). Sharing is sound only because
// nothing can change an empty bytes; this pins the behavior that has to
// stay the same, and that non-empty literals are still fresh per
// evaluation, since those CAN be written through b[i] = v.
//
// ALLOC_BUDGET_N=N is the allocation-budget mode tests/run_tests.sh
// drives under SLANG_GC_STAT: N evaluations of b"", stored the way real
// code stores them, must cost nothing.
import "proc";

extern fn atoi(s: str) -> i32;

gc struct Holder {
    b: bytes,
    n: int,
}

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn empty() -> bytes {
    return b"";
}

fn semantics() {
    let e = b"";
    if len(e) != 0 { die("len"); }
    if e != b"" { die("equal to itself"); }
    if e != empty() { die("equal across functions"); }
    if to_str(e) != "" { die("to_str"); }
    if e == b"x" { die("equal to non-empty"); }
    let joined = e + b"ab";
    if joined != b"ab" || len(e) != 0 { die("concat left"); }
    let joined2 = b"ab" + e;
    if joined2 != b"ab" { die("concat right"); }
    if len(b"ab"[1..1]) != 0 { die("empty slice"); }
    let n = 0;
    for _x in e {
        n = n + 1;
    }
    if n != 0 { die("iteration"); }
    if to_bytes("") != e { die("to_bytes of empty str"); }
    println("semantics");
}

// A non-empty literal written through b[i] must not change the next
// evaluation of the same literal: those are still one fresh copy each.
fn fresh_non_empty() {
    let i = 0;
    while i < 3 {
        let b = b"ab";
        if b != b"ab" { die("non-empty literal reused after a write"); }
        b[0] = 122;
        if b != b"zb" { die("write"); }
        i = i + 1;
    }
    println("fresh_non_empty");
}

// Held in gc structs and lists across collections: the static is not a GC
// object, and marking, sweeping and promotion must all leave it alone.
fn survives_gc() {
    let hs: [Holder] = [];
    let i = 0;
    while i < 2000 {
        push(hs, Holder { b: b"", n: i });
        let junk: [str] = [];
        let j = 0;
        while j < 20 {
            push(junk, to_str(i * j));
            j = j + 1;
        }
        i = i + 1;
    }
    let es: [bytes] = [];
    i = 0;
    while i < 2000 {
        push(es, b"");
        i = i + 1;
    }
    for h in hs {
        if len(h.b) != 0 || h.b != b"" { die("holder field"); }
    }
    for x in es {
        if len(x) != 0 { die("list element"); }
    }
    let h0 = hs[0];
    h0.b = b"set";
    if hs[1].b != b"" { die("reassigning one field changed another"); }
    h0.b = b"";
    if h0.b != b"" { die("reassign back"); }
    println("survives_gc");
}

fn budget(n: int) {
    let h = Holder { b: b"x", n: 0 };
    let i = 0;
    while i < n {
        h.b = b"";
        h.n = h.n + len(h.b);
        i = i + 1;
    }
    if h.n != 0 { die("budget"); }
}

let nr = proc.getenv("ALLOC_BUDGET_N");
guard let ns = nr else {
    semantics();
    fresh_non_empty();
    survives_gc();
    exit(0);
}
budget(atoi(ns));
