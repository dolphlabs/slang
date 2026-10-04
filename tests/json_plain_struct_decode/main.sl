// json.decode into a plain struct. Only gc structs had codecs until
// fix-gc.md 2.1; this was a compile error saying to declare it 'gc struct'.
import "json";

struct Plain { v: int }

let r: result[Plain, str] = json.decode("{\"v\": 1}");
guard let p = r else let e = err_of(r) {
    println("decode failed: " + e);
    exit(1);
}
println(p.v);
