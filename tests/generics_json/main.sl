// json.encode / json.decode over generic struct instances. The codecs are
// generated per distinct type reached, and an instance is a distinct type,
// so Box[int], Box[str] and Pair[str, Point] each get their own.
import "json";

gc struct Box[T] {
    v: T,
}

gc struct Point {
    x: int,
    y: int,
}

gc struct Pair[K, V] {
    k: K,
    v: V,
}

// recursion through opt[...] must not send codec discovery around forever
gc struct Link[T] {
    val: T,
    next: opt[Link[T]],
}

let bi = Box[int] { v: 7 };
let s1: str = json.encode(bi);
println(s1);
let r1: result[Box[int], str] = json.decode(s1);
println((r1 ?? Box[int] { v: -1 }).v);

let bs = Box { v: "text" };
let s2: str = json.encode(bs);
println(s2);
let r2: result[Box[str], str] = json.decode(s2);
println((r2 ?? Box[str] { v: "" }).v);

let pp = Pair { k: "origin", v: Point { x: 3, y: 4 } };
let s3: str = json.encode(pp);
println(s3);
let r3: result[Pair[str, Point], str] = json.decode(s3);
guard let back = r3 else {
    println("BUG: Pair did not round-trip");
    exit(1);
}
println(back.k);
println(back.v.y);

let chain = Link[int] { val: 1, next: some(Link[int] { val: 2, next: none }) };
let s4: str = json.encode(chain);
println(s4);
let r4: result[Link[int], str] = json.decode(s4);
guard let c2 = r4 else {
    println("BUG: Link did not round-trip");
    exit(1);
}
guard let nx = c2.next else {
    println("BUG: Link lost its tail");
    exit(1);
}
println(c2.val + nx.val);

// a wrong type for a field is an error, not a silent zero
let bad: result[Box[int], str] = json.decode("{\"v\": \"seven\"}");
guard let _b = bad else {
    println("rejected");
    exit(0);
}
println("BUG: accepted a string for an int");
