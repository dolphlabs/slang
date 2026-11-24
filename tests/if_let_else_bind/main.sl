gc struct ApiErr {
    code: int,
    detail: str,
    tags: [str],
}

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn parse_pair(a: str, b: str) -> result[int, str] {
    if let x = to_int(a) {
        if let y = to_int(b) {
            return ok(x + y);
        } else |e2| {
            return err("b:" + e2);
        }
    } else |e1| {
        return err("a:" + e1);
    }
}

fn fetch_gc(i: int) -> result[str, ApiErr] {
    if i % 3 == 0 {
        return ok("ok-" + to_str(i));
    }
    return err(ApiErr {
        code: 500 + (i % 10),
        detail: "fail-" + to_str(i),
        tags: ["net", to_str(i)],
    });
}

let r1 = parse_pair("12", "30");
if let sum = r1 {
    println("sum=" + to_str(sum));
} else |e| {
    die("unexpected err: " + e);
}

// Fallthrough after else |e|
let seen = "";
let r2 = parse_pair("x", "5");
if let sum = r2 {
    die("unexpected ok: " + to_str(sum));
} else |e| {
    seen = e;
}
println("after1=" + seen);

let r3 = parse_pair("5", "y");
if let sum = r3 {
    die("unexpected ok: " + to_str(sum));
} else |e| {
    seen = e;
}
println("after2=" + seen);

// Legacy compatibility + else if
let r4 = parse_pair("7", "8");
if let sum = r4 {
    println("legacy_ok=" + to_str(sum));
} else let e = err_of(r4) {
    die("legacy err: " + e);
}

let o: opt[int] = none;
if let v = o {
    die("unexpected some " + to_str(v));
} else if true {
    println("else_if_ok");
}

// GC struct error under allocation pressure
let ok_count = 0;
let err_sum = 0;
for i in 0..1500 {
    let r = fetch_gc(i);
    if let s = r {
        let pad = [s, to_str(i), "x"];
        if pad[0] == s {
            ok_count += 1;
        }
    } else |e| {
        let pad = [e.detail, "p1", "p2"];
        if len(e.tags) != 2 || pad[0] != "fail-" + to_str(i) {
            die("gc api err mismatch");
        }
        err_sum += e.code;
    }
}
println("gc=" + to_str(ok_count) + "," + to_str(err_sum));
