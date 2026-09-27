// A value-type result (all payloads non-GC) may hold a plain struct
// by value -- and a struct may hold such a result by value. Both
// directions need the bodies in dependency order.
struct Addr { host: str, port: int }

let r: result[Addr, int] = ok(Addr { host: "db", port: 5432 });
guard let a = r else {
    println("BUG: expected ok");
    exit(1);
}
println(a.host);
println(a.port);

struct Holder { r: result[Addr, int], name: str }
let h = Holder { r: ok(Addr { host: "x", port: 80 }), name: "h" };
guard let ha = h.r else {
    println("BUG: expected ok");
    exit(1);
}
println(ha.host);
println(h.name);

// nested value-results lay out innermost-first
let n: result[result[int, int], str] = ok(ok(3));
guard let o = n else {
    println("BUG: expected outer ok");
    exit(1);
}
guard let v = o else {
    println("BUG: expected inner ok");
    exit(1);
}
println(v);

let e: result[Addr, int] = err(3);
guard let b = e else {
    println("got expected err");
    exit(0);
}
println("BUG: expected err");
