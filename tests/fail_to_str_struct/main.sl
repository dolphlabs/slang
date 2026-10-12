// to_str of a struct has no conversion: a located error that names the
// fix, not "internal: no str conversion" at line 0.
struct Point { x: int, y: int }

let p = Point { x: 1, y: 2 };
println(to_str(p));
