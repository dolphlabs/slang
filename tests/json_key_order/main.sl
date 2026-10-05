// A struct decoder tries the key it expects next (declaration order) as a
// literal before scanning and comparing; every other arrangement of keys
// must decode exactly as before. The first occurrence of a key counts.
import "json";

struct Item { sku: str, qty: int, price_cents: int }
gc struct Box { id: int, item: Item, tags: [str] }

fn show(label: str, body: str) {
    let r: result[Item, str] = json.decode(body);
    guard let it = r else let e = err_of(r) {
        println(label + ": err: " + e);
        return;
    }
    println(label + ": " + it.sku + " " + to_str(it.qty) + " " +
            to_str(it.price_cents));
}

show("in order", "{\"sku\":\"A\",\"qty\":1,\"price_cents\":10}");
show("reversed", "{\"price_cents\":10,\"qty\":1,\"sku\":\"A\"}");
show("rotated", "{\"qty\":1,\"price_cents\":10,\"sku\":\"A\"}");
show("spaced", "{ \"sku\" : \"A\" ,\n\t\"qty\"\t:1 , \"price_cents\":  10 }");
show("unknown between", "{\"sku\":\"A\",\"x\":[1,{\"qty\":9}],\"qty\":1,\"y\":null,\"price_cents\":10}");
show("duplicate after a hit", "{\"sku\":\"A\",\"sku\":\"B\",\"qty\":1,\"price_cents\":10}");
show("duplicate later", "{\"sku\":\"A\",\"qty\":1,\"price_cents\":10,\"qty\":2,\"sku\":\"C\"}");
show("escaped key", "{\"\\u0073ku\":\"A\",\"q\\u0074y\":1,\"price_cents\":10}");
show("prefix of a key", "{\"skus\":\"Z\",\"sku\":\"A\",\"qty\":1,\"price_cents\":10}");
show("key prefix of it", "{\"sk\":\"Z\",\"sku\":\"A\",\"qty\":1,\"price_cents\":10}");
show("missing colon", "{\"sku\" \"A\",\"qty\":1,\"price_cents\":10}");
show("missing field", "{\"sku\":\"A\",\"qty\":1}");
show("unterminated key", "{\"sku");

let br: result[Box, str] = json.decode("{\"tags\":[\"t\"],\"item\":{\"qty\":2,\"sku\":\"N\",\"price_cents\":3},\"id\":7}");
guard let b = br else let e = err_of(br) {
    println("nested: err: " + e);
    exit(1);
}
println("nested: " + to_str(b.id) + " " + b.item.sku + " " + to_str(b.item.qty) +
        " " + to_str(len(b.tags)));
