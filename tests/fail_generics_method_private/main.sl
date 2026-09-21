// a method of a generic struct, not marked pub, called from another package.
import "stash";

let s = stash.Slot[int] { v: 1 };
println(s.raw());
