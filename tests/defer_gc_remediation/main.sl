import "strings";

gc struct GcNode {
    id: int,
    label: str,
}

struct OwnBox {
    s: str,
}

struct InnerVal {
    pad: int,
    s: str,
    node: opt[GcNode],
    res: result[str, str],
}

struct OwnHolder {
    pad: int,
    inner: InnerVal,
}

struct DeepInner {
    g: GcNode,
}

struct DeepOuter {
    pad: int,
    inner: own DeepInner,
}

struct ValWithOwn {
    pad: int,
    inner: own DeepInner,
}

struct ValBox {
    id: int,
    s: str,
}

impl ValBox {
    fn show(self: &ValBox) -> str {
        return self.s;
    }
}

fn read_own_box(b: &own OwnBox) -> str {
    return (*b).s;
}

fn close_holder(h: own OwnHolder) {
    if len(h.inner.s) == 0 {
        println("FAIL empty inner.s");
        exit(1);
    }
    if let n = h.inner.node {
        if n.id != 42 {
            println("FAIL node.id");
            exit(1);
        }
    }
    if let rs = h.inner.res {
        if len(rs) == 0 {
            println("FAIL res ok");
            exit(1);
        }
    }
}

fn close_deep(o: own DeepOuter) {
    if o.inner.g.id != 77 || len(o.inner.g.label) == 0 {
        println("FAIL close_deep");
        exit(1);
    }
}

fn close_val_with_own(v: ValWithOwn) {
    if v.inner.g.id != 88 || len(v.inner.g.label) == 0 {
        println("FAIL close_val_with_own");
        exit(1);
    }
}

fn read_box(r: &ValBox, out: GcNode) {
    out.label = (*r).s;
}

fn read_str(r: &str, out: GcNode) {
    out.label = *r;
}

fn touch_mut_str(r: &mut str, out: GcNode) {
    *r = *r + "-end";
    out.label = *r;
}

// Defect 1: &own borrow of own variable with drop + GC roots
fn take_own_box(b: own OwnBox) -> int {
    return len(b.s);
}

fn test_cond_defer_else_move(cond: bool) -> int {
    let b: own OwnBox = OwnBox { s: "cond-" + strings.repeat("g", 48) };
    let moved_len = 0;
    if cond {
        defer read_own_box(&b);
    } else {
        moved_len = take_own_box(b);
    }
    let acc = moved_len;
    for i in 0..300 {
        let g = GcNode { id: i, label: strings.repeat("z", 16) };
        acc += g.id;
    }
    return acc;
}

fn test_ref_own_gc(out: GcNode) {
    let b: own OwnBox = OwnBox { s: "own-" + strings.repeat("a", 64) };
    defer read_own_box(&b);
    let acc = 0;
    for i in 0..500 {
        let g = GcNode { id: i, label: strings.repeat("z", 16) };
        acc += g.id;
    }
    out.id += acc % 10;
    out.label = b.s;
}

// Defect 2: conditional defer of own struct with composite GC-bearing fields across for + select
fn test_cond_own_composite(cond: bool) -> int {
    if cond {
        let h: own OwnHolder = OwnHolder {
            pad: 7,
            inner: InnerVal {
                pad: 9,
                s: "inner-" + strings.repeat("b", 32),
                node: some(GcNode { id: 42, label: "opt-" + strings.repeat("c", 32) }),
                res: ok("res-" + strings.repeat("d", 32)),
            },
        };
        defer close_holder(h);
    }
    let acc = 0;
    for i in 0..500 {
        let g = GcNode { id: i, label: "loop-" + to_str(i) };
        acc += g.id;
    }
    let ch: chan[GcNode] = make_chan(1);
    chan_send(ch, GcNode { id: 5, label: "sel" });
    select {
        case let v = chan_recv(ch) {
            if let n = v {
                acc += n.id;
            }
        }
    }
    return acc;
}

// Defect 3: nested own struct (own Outer { inner: own Inner { g: GcNode } }) + value struct with own Inner in loop
fn test_nested_own_loop(cond: bool) -> int {
    let o: own DeepOuter = DeepOuter {
        pad: 1,
        inner: DeepInner { g: GcNode { id: 77, label: "deep-" + strings.repeat("e", 48) } },
    };
    defer close_deep(o);
    if cond {
        let v = ValWithOwn {
            pad: 2,
            inner: DeepInner { g: GcNode { id: 88, label: "val-" + strings.repeat("f", 48) } },
        };
        defer close_val_with_own(v);
    }
    let acc = 0;
    for i in 0..500 {
        let g = GcNode { id: i, label: strings.repeat("z", 16) };
        acc += g.id;
    }
    return acc;
}

// Defect 4: derived borrows (let r = &x; chained r2 = r; conditional re-assign; &mut str; method on &ValBox)
fn test_derived_borrows(cond: bool) -> str {
    let x = ValBox { id: 1, s: "alive-" + strings.repeat("a", 64) };
    let r = &x;
    let out1 = GcNode { id: 0, label: "" };
    defer read_box(r, out1);

    let y = "str-" + strings.repeat("b", 64);
    let r1 = &y;
    let r2 = r1;
    let out2 = GcNode { id: 0, label: "" };
    defer read_str(r2, out2);

    let z = "mut-" + strings.repeat("c", 64);
    let rm = &mut z;
    let out3 = GcNode { id: 0, label: "" };
    defer touch_mut_str(rm, out3);

    let a = ValBox { id: 2, s: "pickA-" + strings.repeat("d", 64) };
    let b = ValBox { id: 3, s: "pickB-" + strings.repeat("e", 64) };
    let rc = &a;
    if cond {
        rc = &b;
    }
    let out4 = GcNode { id: 0, label: "" };
    defer read_box(rc, out4);

    let m = ValBox { id: 4, s: "meth-" + strings.repeat("f", 64) };
    let rm2 = &m;
    defer rm2.show();

    for i in 0..5000 {
        let junk = GcNode { id: i, label: strings.repeat("z", 16) };
        let _ = junk.id;
    }
    return "ok";
}

fn run_derived_str_check(out: GcNode) {
    let s = "alive-" + strings.repeat("a", 64);
    let r = &s;
    let r2 = r;
    defer read_str(r2, out);
    for i in 0..5000 {
        let junk = GcNode { id: i, label: strings.repeat("z", 16) };
        let _ = junk.id;
    }
}

fn run_derived_box_check(out: GcNode) {
    let b = ValBox { id: 1, s: "alive-" + strings.repeat("a", 64) };
    let r = &b;
    defer read_box(r, out);
    for i in 0..5000 {
        let junk = GcNode { id: i, label: strings.repeat("z", 16) };
        let _ = junk.id;
    }
}

fn main_test() {
    let out_own = GcNode { id: 0, label: "" };
    test_ref_own_gc(out_own);
    println("own=" + to_str(len(out_own.label)));

    println("condF=" + to_str(test_cond_own_composite(false)));
    println("condT=" + to_str(test_cond_own_composite(true)));
    println("deepF=" + to_str(test_nested_own_loop(false)));
    println("deepT=" + to_str(test_nested_own_loop(true)));
    println("derived=" + test_derived_borrows(true));

    let out_b = GcNode { id: 0, label: "" };
    run_derived_box_check(out_b);
    if out_b.label != "alive-" + strings.repeat("a", 64) {
        println("FAIL box corrupted: " + out_b.label);
        exit(1);
    }
    let out_s = GcNode { id: 0, label: "" };
    run_derived_str_check(out_s);
    if out_s.label != "alive-" + strings.repeat("a", 64) {
        println("FAIL str corrupted: " + out_s.label);
        exit(1);
    }
    println("condMoveF=" + to_str(test_cond_defer_else_move(false)));
    println("condMoveT=" + to_str(test_cond_defer_else_move(true)));
    println("verified=ok");
}

main_test();
