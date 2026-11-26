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

fn f() {
    let c = Counter { n: 0 };
    defer c.show();
    c.inc();
}

f();
