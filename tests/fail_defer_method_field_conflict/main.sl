struct Counter {
    n: int,
}

impl Counter {
    fn show(self: &Counter) {
        println(self.n);
    }

    fn inc(self: &mut Counter) {
        self.n += 1;
    }
}

struct Holder {
    c: Counter,
}

fn f() {
    let h = Holder { c: Counter { n: 0 } };
    defer h.c.show();
    h.c.inc();
}

f();
