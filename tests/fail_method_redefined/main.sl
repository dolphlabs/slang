// Two methods of the same name on ONE struct are still a redefinition.
gc struct Store { v: int }
impl Store {
    fn get(self: Store) -> int { return self.v; }
}
impl Store {
    fn get(self: Store) -> int { return 0; }
}
let s = Store { v: 1 };
println(s.get());
