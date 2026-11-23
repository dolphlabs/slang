// A reference into a list's storage is not sound (an alias can push and
// move it), so borrowing an element is refused with the way out. It used
// to reach the C compiler as "cannot take the address of an rvalue".
struct P { x: int }
fn get(p: &P) -> int { return p.x; }
let ps: [P] = [P { x: 1 }];
println(get(&ps[0]));
