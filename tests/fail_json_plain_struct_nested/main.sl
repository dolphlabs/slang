// A plain struct nested in a gc struct is caught where it is reached, and
// named, not the outer one.
import "json";

struct Inner { n: int }
gc struct Outer { inner: Inner, tag: str }

let o = Outer { inner: Inner { n: 1 }, tag: "t" };
let s: str = json.encode(o);
println(s);
