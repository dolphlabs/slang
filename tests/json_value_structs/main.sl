// json of plain (value) structs (fix-gc.md 2.1): decoded in place, into a
// binding or a list's or map's own slot, encoded through `.`; nested in each
// other and in a gc struct, in lists, map values and opt fields; and a
// missing field is still an error. GC-stress listed: a [Item] is one
// buffer whose slots hold the strs and lists the collector must reach.
import "json";

struct Point {
    x: int,
    y: int,
}

struct Item {
    sku: str,
    qty: int,
    tags: [str],
    note: opt[str],
}

struct Box {
    corner: Point,
    label: str,
}

gc struct Order {
    id: int,
    items: [Item],
    box: Box,
    by_sku: map[str]Item,
}

let body = "{\"id\":7,\"items\":[{\"sku\":\"A\",\"qty\":2,\"tags\":[\"x\",\"y\"]},{\"sku\":\"B\",\"qty\":5,\"tags\":[],\"note\":\"fragile\"}],\"box\":{\"corner\":{\"x\":1,\"y\":-2},\"label\":\"crate\"},\"by_sku\":{\"A\":{\"sku\":\"A\",\"qty\":2,\"tags\":[]}}}";
let r: result[Order, str] = json.decode(to_bytes(body));
guard let o = r else let e = err_of(r) {
    println("decode failed: " + e);
    exit(1);
}
println(to_str(o.id) + " " + to_str(len(o.items)) + " " + o.items[1].sku + " " + to_str(o.items[1].qty));
println(o.box.label + " " + to_str(o.box.corner.x) + "," + to_str(o.box.corner.y));
println(o.items[1].note ?? "none");
println(o.items[0].note ?? "none");
println(json.encode(o));

let pr: result[Point, str] = json.decode(to_bytes("{\"x\":3,\"y\":4}"));
guard let p = pr else {
    println("point failed");
    exit(1);
}
println(to_str(p.x + p.y));
println(json.encode(p));
let ps: result[[Point], str] = json.decode(to_bytes("[{\"x\":1,\"y\":2},{\"x\":3,\"y\":4}]"));
guard let pl = ps else {
    println("points failed");
    exit(1);
}
println(to_str(len(pl)) + " " + to_str(pl[1].y));
println(json.encode(pl));
let bad: result[Point, str] = json.decode(to_bytes("{\"x\":1}"));
println(err_of(bad));
