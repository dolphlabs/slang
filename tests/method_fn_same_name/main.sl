// A method may share its name with a package-level function, and two
// structs may each have a method of the same name. They used to share
// one C symbol and one lookup namespace, so each of these was
// "redefinition of function".
import "shapes";
fn get(x: int) -> int { return x + 1; }
gc struct Store { v: int }
impl Store {
    fn get(self: Store) -> int { return get(self.v) * 10; }
    fn close(self: Store) -> int { return 5; }
}
fn close(n: int) -> int { return n; }
let s = Store { v: 4 };
println(s.get());
println(get(4));
println(close(9) + s.close());
let b = shapes.Box { w: 3 };
println(b.size());
println(shapes.size(b));
println(b.both());
let g = shapes.Bag { n: 7 };
println(g.size());
let h = spawn get(41);
println(join_wait(h) ?? -1);
let f = get;
println(f(1));
