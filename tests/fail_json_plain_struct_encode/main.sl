// json.encode of a plain struct. Only gc structs have codecs; this used to reach
// the C compiler and fail there, about generated code.
import "json";

struct Plain { v: int }

let s: str = json.encode(Plain { v: 1 });
println(s);
