// A generic function declared in one package, called from another --
// including with an argument type only the importing package knows.
import "stash";

struct Local {
    n: int,
}

println(stash.map_len([1, 2, 3]));
println(stash.map_len([Local { n: 1 }, Local { n: 2 }]));

let p = stash.make_pair(1, "x");
println(p.first);
println(p.second);

// an argument type from THIS package, unified inside the DECLARING
// package's own canonicalization context
let p2 = stash.make_pair(Local { n: 5 }, 2.5);
println(p2.first.n);
println(p2.second);
