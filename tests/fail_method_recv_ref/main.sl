// A method that returns a reference into `self`, called on a temporary:
// the reference would outlive its owner.
struct Bag { n: int }
impl Bag {
    fn get(self: &Bag) -> &int { return &self.n; }
}
fn make() -> Bag { return Bag { n: 1 }; }
let r = make().get();
println(*r);
