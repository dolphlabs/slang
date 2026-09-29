// Two different packages whose directories share a base name. A package
// was named after its directory, and every symbol, type and import was
// keyed on that name, so these merged into one package "util" and failed
// with "redefinition of function 'make'". Each is its own package now.
import "a/util";
import "b/util" as butil;
import "x";
import "y";

// Same struct name, function name and method name in both.
let p = util.make(1);
let q = butil.make(2);
println(to_str(p.get()) + " " + to_str(q.get()));

// Types stay distinct: a list of each.
let ps: [util.Box] = [];
push(ps, util.make(5));
let qs: [butil.Box] = [];
push(qs, butil.make(5));
println(to_str(ps[0].get()) + " " + to_str(qs[0].get()));

// x and y each import their OWN "util" -- the usual shape, since every
// library is free to have a helper package called util.
println(x.label() + " " + to_str(y.num()));
