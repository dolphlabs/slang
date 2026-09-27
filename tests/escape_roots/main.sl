// Escape audit: stack-box candidates (explicit gc conversion lets)
// holding GC fields. Fields must survive churn in the same frame,
// and a returned box must come back heap-allocated and stay valid.
struct Rec {
    name: str,
    items: [int],
}

fn churn() {
    let i = 0;
    while i < 2000 {
        push(["pad"], "padding-padding-" + to_str(i));
        i = i + 1;
    }
}

fn mk(name: str) -> Rec {
    let g: gc Rec = Rec { name: name, items: [1, 2, 3] };
    churn();
    return g;
}

// 1. boxed fields across churn in the same frame
let g: gc Rec = Rec { name: "KEEP-BOX", items: [4, 5] };
churn();
println(g.name);
println(len(g.items));

// 2. returned box stays valid across caller churn
let h = mk("KEEP-RET");
churn();
println(h.name);
println(len(h.items));

// 3. boxed value stored into a heap list, read back after churn
let l: [Rec] = [];
let j: gc Rec = Rec { name: "KEEP-LIST", items: [6] };
churn();
push(l, j);
churn();
println(l[0].name);

// 4. nested value struct inside a gc box: the tracer must walk
// through Inner to its str field, not stop at the struct boundary
struct Inner {
    s: str,
}

struct Outer {
    inner: Inner,
    n: int,
}

let o: gc Outer = Outer { inner: Inner { s: "KEEP-NEST" }, n: 1 };
churn();
println(o.inner.s);
