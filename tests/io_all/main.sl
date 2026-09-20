import "io";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

// read_line and read_all share one buffer: what read_line did not take
// is exactly what read_all returns.
let r = io.read_line();
guard let maybe = r else let e = err_of(r) { die("read_line: " + e); }
guard let first = maybe else { die("unexpected EOF"); }
println("first: " + first);

let all = io.read_all();
guard let rest = all else let e2 = err_of(all) { die("read_all: " + e2); }
println("rest: " + to_str(len(rest)) + " bytes");
println(to_str(rest));

let done = io.read_all();
guard let none_left = done else let e3 = err_of(done) { die("second read_all: " + e3); }
println("after: " + to_str(len(none_left)));
