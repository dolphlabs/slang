import "json";

gc struct Address { city: str, zip: str }
gc struct Person { name: str, addr: Address }

let body = "{\"name\":\"Ada\",\"addr\":{\"city\":5,\"zip\":\"SW1\"}}";
let r: result[Person, str] = json.decode(body);
guard let p = r else let e = err_of(r) {
    println("rejected: " + e);
    exit(1);
}
println("hello, " + p.name);
