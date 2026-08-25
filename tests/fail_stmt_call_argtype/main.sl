// a bare statement-level call must validate its arguments just like
// any other call site -- it must not silently reinterpret a
// mismatched value (e.g. a str pointer read as an int)
fn takes_int(n: int) {
    println(n);
}
takes_int("not an int");
