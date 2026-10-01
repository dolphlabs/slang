// json.decode keeps UTF-8 as it arrives. It used to widen every byte past
// 0x7F as if it were a code point, so "café" decoded to "cafÃ©": every
// non-ASCII string a server received as JSON came back corrupted.
import "json";

gc struct Msg {
    text: str,
    tags: map[str]str,
}

let src = "{\"text\":\"café ☕ naïve 日本\",\"tags\":{\"ключ\":\"значение\",\"mixed\":\"é\\n\\u00e9\"}}";
let r: result[Msg, str] = json.decode(src);
guard let m = r else let e = err_of(r) {
    println("FAIL decode: " + e);
    exit(1);
}
println(m.text);
println(len(m.text));
println(m.tags["ключ"]);
println(m.tags["mixed"]);

// what encode writes, decode reads back unchanged
let again: result[Msg, str] = json.decode(json.encode(m));
guard let m2 = again else { println("FAIL round trip"); exit(1); }
if m2.text != m.text || m2.tags["ключ"] != m.tags["ключ"] {
    println("FAIL round trip changed the text");
    exit(1);
}
println("round trip ok");
