import "json";
struct Empty {}
struct Outer { value: Empty }
let parsed: result[Outer, str] = json.decode("{\"value\":{}}");
guard let value = parsed else let e = err_of(parsed) { panic(e); }
assert(json.encode(value) == "{\"value\":{}}");
println("empty value struct JSON ok");
