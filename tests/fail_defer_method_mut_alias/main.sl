struct Counter {
    n: int,
}

impl Counter {
    fn inc(self: &mut Counter) {
        self.n += 1;
    }
}

fn f() -> int {
    let c = Counter { n: 0 };
    defer c.inc();
    return c.n;
}

println(f());
