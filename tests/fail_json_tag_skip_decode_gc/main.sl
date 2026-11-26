import "json";

gc struct Child { x: int }
gc struct Parent {
    name: str,
    child: Child `json:"-"`,
}

let r: result[Parent, str] = json.decode("{\"name\":\"a\"}");
println(is_ok(r));
