// if let unwraps an opt or result into a branch of its own; unlike a
// guard, either branch may fall through, and each binding lives only
// inside its branch.
gc struct User {
    name: str,
    tags: [str],
}

fn find(users: [User], name: str) -> opt[User] {
    for u in users {
        if u.name == name { return some(u); }
    }
    return none;
}

fn parse(s: str) -> result[int, str] {
    return to_int(s);
}

let users = [User { name: "ada", tags: ["math"] }, User { name: "bo", tags: [] }];

if let u = find(users, "ada") {
    println("found " + u.name + " " + to_str(len(u.tags)));
}
if let u = find(users, "cy") {
    println("unexpected " + u.name);
} else {
    println("no cy");
}

let r = parse("42");
if let n = r {
    println(n + 1);
} else let e = err_of(r) {
    println("bad: " + e);
}
let r2 = parse("x");
if let n = r2 {
    println(n);
} else let e = err_of(r2) {
    println("bad: " + e);
}

// else if, and the same name reused in each branch
let o: opt[int] = none;
if let v = o {
    println(v);
} else if len(users) == 2 {
    println("two users");
}

// nested, and the error branch falling through into the rest
let total = 0;
for s in ["1", "two", "3"] {
    let pr = parse(s);
    if let n = pr {
        if let u = find(users, "bo") {
            total += n + len(u.tags);
        }
    } else let e = err_of(pr) {
        println("skip " + s);
    }
}
println(total);

// the binding survives allocation inside its branch (GC stress lists)
let kept = 0;
for i in 0..2000 {
    if let u = find(users, "ada") {
        let pad = [to_str(i), to_str(i * 2), to_str(i * 3)];
        push(pad, u.name);
        if pad[3] == "ada" && u.tags[0] == "math" { kept += 1; }
    }
}
println(kept);
