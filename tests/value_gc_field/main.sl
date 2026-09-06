struct Person {
    name: str,
    tags: [str],
}

fn greet(p: Person) -> str {
    p.name + ":" + to_str(len(p.tags))
}

let p = Person { name: "Ada", tags: ["math"] };
let q = p;
println(greet(q));
println(q.tags[0]);

fn grow(p: Person) -> Person {
    push(p.tags, "more");
    p
}

let r = grow(p);
println(to_str(len(r.tags)));
println(p.name);
