// methods take a receiver the fn type does not name, so they are not
// usable as function values
gc struct Counter { n: int }
impl Counter {
    fn bump(self: Counter) -> int { return self.n + 1; }
}
let f: fn(Counter) -> int = bump;
println(f(Counter { n: 1 }));
