// json.decode into a plain struct: same rule, same message shape.
import "json";

struct Plain { v: int }

let r: result[Plain, str] = json.decode("{\"v\": 1}");
println("unreachable");
