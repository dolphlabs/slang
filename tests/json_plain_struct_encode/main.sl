// json.encode of a plain struct. Only gc structs had codecs until
// fix-gc.md 2.1; this was a compile error saying to declare it 'gc struct'.
import "json";

struct Plain { v: int }

let s: str = json.encode(Plain { v: 1 });
println(s);
