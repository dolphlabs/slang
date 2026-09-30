// C's atoi says 8080, 80 and 0. slang says:
for s in ["8080", "80x80", ""] {
    let r = to_int(s);
    guard let n = r else let e = err_of(r) {
        println(inspect(s) + "  ->  err: " + e);
        continue;
    }
    println(inspect(s) + "  ->  " + to_str(n));
}
