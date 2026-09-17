// A method is not a package-level function: with no `fn close` in the
// package, a bare close(s) must not resolve to Store's method.
gc struct Store { v: int }
impl Store {
    fn close(self: Store) -> int { return self.v; }
}
let s = Store { v: 1 };
println(close(s));
