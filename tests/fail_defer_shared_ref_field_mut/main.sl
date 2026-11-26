struct Counter {
    n: int,
}

impl Counter {
    fn inc(self: &mut Counter) {
        self.n += 1;
    }
}

struct Holder {
    c: Counter,
}

fn f() {
    let h = Holder { c: Counter { n: 0 } };
    let rh = &h;
    defer rh.c.inc();
}

f();
