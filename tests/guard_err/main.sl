fn parse_ok() -> result[int, str] {
    return ok(42);
}

fn parse_bad() -> result[int, str] {
    return err("bad token");
}

let good = parse_ok();
guard let v = good else let e = err_of(good) {
    println("unexpected: " + e);
    exit(1);
}
println(v);

let bad = parse_bad();
guard let v2 = bad else let e = err_of(bad) {
    println("got err: " + e);
    exit(0);
}
println("unexpected ok");
exit(1);
