// A `gc struct` literal nested in another one's fields.
//
// When escape analysis keeps a non-escaping `let x = Outer { ... }` on the
// stack, only that literal is built by value. The literals inside its
// fields are still heap objects reached through pointer fields; the flag
// meant for the outer one used to stay set while they were generated, so
// each was built by value into a pointer field and the C did not compile.

gc struct Inner {
    v: str,
    n: int,
}

gc struct Middle {
    inner: Inner,
    tag: str,
}

gc struct Outer {
    mid: Middle,
    extra: Inner,
    items: [Inner],
    maybe: opt[Inner],
}

// allocate enough that a collection at a tiny threshold lands between the
// nested literal being built and being read
fn churn() -> int {
    let total = 0;
    let i = 0;
    while i < 400 {
        let junk = Inner { v: "junk" + to_str(i), n: i };
        total = total + junk.n;
        i = i + 1;
    }
    return total;
}

fn build(seed: int) -> int {
    let o = Outer {
        mid: Middle { inner: Inner { v: "deep", n: seed }, tag: "mid" },
        extra: Inner { v: "extra", n: seed + 1 },
        items: [Inner { v: "a", n: 1 }, Inner { v: "b", n: 2 }],
        maybe: some(Inner { v: "opt", n: 3 })
    };
    churn();
    let m = o.maybe ?? Inner { v: "", n: 0 };
    return o.mid.inner.n + o.extra.n + o.items[0].n + o.items[1].n + m.n;
}

// the shape from the report: one literal directly in another
let c = Middle { inner: Inner { v: "deep", n: 5 }, tag: "t" };
println(c.inner.v);
println(c.inner.n);

// deeper, and with the nested ones inside a list and an opt
let o = Outer {
    mid: Middle { inner: Inner { v: "x", n: 1 }, tag: "m" },
    extra: Inner { v: "e", n: 2 },
    items: [Inner { v: "i0", n: 10 }],
    maybe: none
};
println(o.mid.inner.v + o.extra.v + o.items[0].v);
println(o.mid.tag);

// and the same values still readable after collections
churn();
println(o.mid.inner.v + o.extra.v + o.items[0].v);
println(build(10));
println(build(20));

// The same rooting for a `gc T` value kept on the stack: its string and
// list live on the heap and are reachable only through the box.
struct Rec {
    name: str,
    items: [int],
}

fn gc_box() -> int {
    let g: gc Rec = Rec { name: "gc-" + to_str(7), items: [1, 2, 3] };
    churn();
    return len(g.name) + len(g.items);
}
println(gc_box());

// and a stack-boxed gc struct whose only reference to a list is its field
gc struct Holder {
    items: [Inner],
    tag: str,
}
fn holder_box() -> int {
    let h = Holder { items: [Inner { v: "h0", n: 4 }], tag: "h-" + to_str(1) };
    churn();
    return h.items[0].n + len(h.tag);
}
println(holder_box());
