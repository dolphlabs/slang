struct Counter {
    n: int,
}

impl Counter {
    fn inc(self: &mut Counter) {
        self.n += 1;
    }
}

fn f() {
    let m: map[str]Counter = {"a": Counter { n: 0 }};
    defer m["a"].inc();
}

f();
