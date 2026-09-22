// A generic function not marked pub cannot be called from another package,
// the same rule every other function follows.
import "stash";
println(stash.hidden_id(1));
