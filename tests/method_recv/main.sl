// A method can be called on any expression, not only on a named variable:
// `make().double()`, `a.b.c()`, `xs[0].m()`, `m["k"].m()`, `(p).m()` and
// chains of them. A bare `p.m()` keeps its own (older) AST shape; the two
// must agree.

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn expect(cond: bool, what: str) {
    if !cond {
        die(what);
    }
}

enum Kind {
    Small,
    Big,
}

struct P {
    x: int,
}

impl P {
    fn double(self: P) -> int {
        return self.x * 2;
    }

    fn moved(self: P, dx: int) -> P {
        return P { x: self.x + dx };
    }

    fn sum(self: P, a: int, b: int) -> int {
        return self.x + a + b;
    }

    fn tag(self: P, k: Kind) -> str {
        if k == Kind.Big {
            return "big" + to_str(self.x);
        }
        return "small" + to_str(self.x);
    }

    fn report(self: P) {
        println("report " + to_str(self.x));
    }

    // a value struct receiver is a copy: this cannot change the caller's
    fn bumped(self: P) -> int {
        self.x = self.x + 100;
        return self.x;
    }
}

gc struct Counter {
    n: int,
}

impl Counter {
    fn bump(self: Counter) -> Counter {
        self.n = self.n + 1;
        return self;
    }

    fn get(self: Counter) -> int {
        return self.n;
    }
}

struct Holder {
    inner: P,
    cb: fn(int) -> int,
}

fn triple(n: int) -> int {
    return n * 3;
}

fn make() -> P {
    return P { x: 4 };
}

fn make_counter() -> Counter {
    return Counter { n: 0 };
}

// ---- each receiver form --------------------------------------------------

fn forms() {
    // a call's result
    expect(make().double() == 8, "call result");

    // chained: every link's receiver is the previous call's result
    expect(make().moved(1).moved(2).double() == 14, "chain");
    expect(make_counter().bump().bump().bump().get() == 3, "gc chain");

    // a field of a field: parse_primary folds only ONE dot into a name
    let h = Holder { inner: P { x: 5 }, cb: triple };
    expect(h.inner.double() == 10, "a.b.c()");

    // an element of a list, and a value of a map
    let ps = [P { x: 1 }, P { x: 2 }, P { x: 3 }];
    expect(ps[1].double() == 4, "index receiver");
    let m: map[str]P = {};
    m["k"] = P { x: 7 };
    expect(m["k"].double() == 14, "map receiver");

    // parenthesised
    let p = P { x: 6 };
    expect((p).double() == 12, "parenthesised receiver");
    expect(p.double() == (p).double(), "p.m() and (p).m() agree");
    expect(p.sum(1, 2) == (p).sum(1, 2), "with arguments too");
    println("ok receiver forms");
}

// ---- evaluation: once, and receiver first ---------------------------------

fn trace(tag: str, v: int) -> P {
    println("recv " + tag);
    return P { x: v };
}

fn arg(tag: str, v: int) -> int {
    println("arg " + tag);
    return v;
}

fn ordering() {
    // the receiver runs once, before the arguments, which run left to right
    let total = trace("a", 1).sum(arg("b", 2), arg("c", 3));
    expect(total == 6, "sum");

    // and with no arguments the receiver still runs exactly once
    let d = trace("solo", 9).double();
    expect(d == 18, "double");

    // a receiver nested inside an argument of another method call
    let n = trace("outer", 1).sum(trace("inner", 10).double(), 0);
    expect(n == 21, "nested");
    println("ok ordering");
}

// ---- value vs gc receivers ---------------------------------------------------

fn value_semantics() {
    let p = P { x: 1 };
    expect(p.bumped() == 101, "bumped result");
    expect(p.x == 1, "a value receiver is a copy");
    expect(make().bumped() == 104, "on a temporary");

    let c = make_counter();
    c.bump().bump();
    expect(c.get() == 2, "a gc receiver is shared");
    println("ok value semantics");
}

// ---- calling through a fn-typed field -------------------------------------------

fn fn_fields() {
    let hs = [Holder { inner: P { x: 1 }, cb: triple }];
    expect(hs[0].cb(5) == 15, "fn field on an element");
    println("ok fn field");
}

// ---- other places a call can sit ----------------------------------------------

fn positions() {
    make().report();                         // as a statement
    println(make().double() + make().double());
    println(make().tag(Kind.Big));            // an enum argument
    println(make().moved(1).tag(Kind.Small));
    if make().double() == 8 {
        println("in a condition");
    }
    println("ok positions");
}

forms();
ordering();
value_semantics();
fn_fields();
positions();
