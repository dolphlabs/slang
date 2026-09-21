import "io";

// What the terminal functions do when stdin is not a terminal, which is
// the case in every scripted run (here it is a file).

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

// read_secret is read_line: nothing to switch off, nothing to restore, and
// no newline written on the person's behalf.
let r = io.read_secret();
guard let maybe = r else let e = err_of(r) { die("read_secret: " + e); }
println("secret: " + (maybe ?? "<none>"));

// and it shares the stream with read_line, so nothing is lost or repeated
let r2 = io.read_line();
guard let maybe2 = r2 else let e2 = err_of(r2) { die("read_line: " + e2); }
println("line: " + (maybe2 ?? "<none>"));

// raw mode needs a terminal to be raw
let raw = io.raw_on();
guard let ok = raw else let e3 = err_of(raw) {
    println("raw_on: " + e3);
    // raw_off is harmless when raw mode was never on
    let off = io.raw_off();
    guard let ok2 = off else let e4 = err_of(off) { die("raw_off: " + e4); }
    println("raw_off ok");
}
