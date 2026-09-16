// `pub fn` inside `impl` exports a method to other packages.
//
// This used to be impossible in both directions at once: the parser
// rejected `pub` inside `impl`, while the type checker already refused a
// non-pub method called from another package -- with an error telling
// the caller to "add 'pub'", which then failed to parse. No method could
// be called from outside its own package.
import "geom";

let p = geom.Point { x: 3, y: 4 };
println(p.sum());
let q = p.moved(1, 1);
println(q.sum());
println(p.area());      // a pub method calling a private one
