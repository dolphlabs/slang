// A method without `pub` stays private to its package.
import "geom";

let p = geom.Point { x: 3, y: 4 };
println(p.secret());
