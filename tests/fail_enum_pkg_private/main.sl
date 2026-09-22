// An enum not marked pub cannot be named from another package, the same
// rule every other type follows.
import "orders";

let x = orders.Internal.A;
println(to_str(x));
