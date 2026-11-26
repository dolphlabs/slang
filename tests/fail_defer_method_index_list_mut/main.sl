struct Counter {
    n: int,
}

impl Counter {
    fn inc(self: &mut Counter) {
        self.n += 1;
    }
}

fn f() {
    let xs: [Counter] = [Counter { n: 0 }];
    defer xs[0].inc();
}

f();
