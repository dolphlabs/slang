struct S {
    x: int,
}

impl S {
    fn bump(self: &mut S) {
        self.x += 1;
    }
}

fn f(cond: bool) {
    if cond {
        let s = S { x: 1 };
        defer s.bump();
    }
}

f(true);
