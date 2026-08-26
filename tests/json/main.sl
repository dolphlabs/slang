// json.decode/json.encode: the target type for decode is inferred
// from the binding's annotation (same mechanism opt[T]/result[T,E]
// already use for none/ok/err), and a decoder/encoder function is
// generated per distinct struct/opt/list/map[str,_] type reached,
// the same way opt[T] and result[T,E] get one C typedef per distinct
// instantiation.
import "json";

struct Address {
    city: str,
    zip: str,
}

struct Person {
    name: str,
    age: i32,
    email: opt[str],
    tags: [str],
    addr: Address,
}

// a self-referential struct (through opt[Self], which is a pointer
// at the C level) must not send the compiler into infinite recursion
// while discovering nested codecs
struct Node {
    value: i32,
    next: opt[Node],
}

fn round_trip() {
    let p = Person{
        name: "Ada",
        age: 36,
        email: some("ada@example.com"),
        tags: ["math", "computing"],
        addr: Address{ city: "London", zip: "SW1" }
    };
    let s: str = json.encode(p);
    println(s);

    let r: result[Person, str] = json.decode(s);
    guard let p2 = r else {
        println("BUG: round-trip decode failed");
        exit(1);
    }
    println(p2.name);
    println(to_str(p2.age));
    guard let em = p2.email else {
        println("BUG: expected email to survive round-trip");
        exit(1);
    }
    println(em);
    println(p2.addr.city);
    println(to_str(len(p2.tags)));
    println(p2.tags[0]);
}

fn opt_none_field() {
    let p = Person{
        name: "Anon",
        age: 0,
        email: none,
        tags: ["none"],
        addr: Address{ city: "Nowhere", zip: "" }
    };
    let s: str = json.encode(p);
    println(s);
    let r: result[Person, str] = json.decode(s);
    guard let p2 = r else {
        println("BUG: decode with none email failed");
        exit(1);
    }
    guard let _em = p2.email else {
        println("email correctly absent after round-trip");
        return;
    }
    println("BUG: expected none for email");
}

fn self_referential() {
    let n = Node{ value: 1, next: some(Node{ value: 2, next: none }) };
    let s: str = json.encode(n);
    println(s);
    let r: result[Node, str] = json.decode(s);
    guard let n2 = r else {
        println("BUG: self-referential decode failed");
        exit(1);
    }
    guard let inner = n2.next else {
        println("BUG: expected next to be some");
        exit(1);
    }
    println(to_str(n2.value));
    println(to_str(inner.value));
    guard let _tail = inner.next else {
        println("tail correctly none");
        return;
    }
    println("BUG: expected tail to be none");
}

fn map_round_trip() {
    let scores: map[str]int = {"alice": 90, "bob": 75};
    let s: str = json.encode(scores);
    println(s);
    let r: result[map[str]int, str] = json.decode(s);
    guard let m2 = r else {
        println("BUG: map decode failed");
        exit(1);
    }
    println(to_str(has(m2, "alice")));
    println(to_str(m2["alice"]));
    println(to_str(m2["bob"]));
}

struct Config {
    name: str,
    count: i32,
}

fn malformed_json_is_err() {
    let r: result[Config, str] = json.decode("{not valid json");
    guard let _c = r else {
        println("malformed json correctly rejected");
        return;
    }
    println("BUG: accepted malformed json");
}

fn missing_field_is_err() {
    let r: result[Config, str] = json.decode("{\"name\":\"x\"}");
    guard let _c = r else {
        println("missing field correctly rejected");
        return;
    }
    println("BUG: accepted json missing a required field");
}

fn wrong_type_is_err() {
    let r: result[Config, str] =
        json.decode("{\"name\":\"x\",\"count\":\"not a number\"}");
    guard let _c = r else {
        println("wrong field type correctly rejected");
        return;
    }
    println("BUG: accepted a field with the wrong type");
}

fn extra_fields_tolerated() {
    let r: result[Config, str] =
        json.decode("{\"name\":\"x\",\"count\":5,\"extra\":true}");
    guard let c = r else {
        println("BUG: extra fields should be tolerated");
        exit(1);
    }
    println(c.name);
    println(to_str(c.count));
}

struct Point { x: float, y: i32 }

fn negative_and_float() {
    let r: result[Point, str] = json.decode("{\"x\":-3.5,\"y\":-7}");
    guard let p = r else {
        println("BUG: negative/float decode failed");
        exit(1);
    }
    println(to_str(p.x));
    println(to_str(p.y));
}

struct Item { id: i32 }

fn list_of_structs() {
    let r: result[[Item], str] =
        json.decode("[{\"id\":1},{\"id\":2},{\"id\":3}]");
    guard let items = r else {
        println("BUG: list-of-structs decode failed");
        exit(1);
    }
    println(to_str(len(items)));
    println(to_str(items[1].id));
}

fn bytes_input() {
    let b: bytes = to_bytes("{\"name\":\"frombytes\",\"count\":9}");
    let r: result[Config, str] = json.decode(b);
    guard let c = r else {
        println("BUG: bytes decode failed");
        exit(1);
    }
    println(c.name);
    println(to_str(c.count));
}

round_trip();
opt_none_field();
self_referential();
map_round_trip();
malformed_json_is_err();
missing_field_is_err();
wrong_type_is_err();
extra_fields_tolerated();
negative_and_float();
list_of_structs();
bytes_input();
