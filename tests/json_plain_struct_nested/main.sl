// A plain struct nested in a gc struct encodes and decodes with it, held by
// value in the outer struct. This was a compile error naming the inner
// struct until fix-gc.md 2.1.
import "json";

struct Inner { n: int }
gc struct Outer { inner: Inner, tag: str }

let o = Outer { inner: Inner { n: 1 }, tag: "t" };
let s: str = json.encode(o);
println(s);
let r: result[Outer, str] = json.decode(s);
guard let back = r else {
    println("decode failed");
    exit(1);
}
println(to_str(back.inner.n) + " " + back.tag);
