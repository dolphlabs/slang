import "io";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

// read_line until the input ends. Every path through the loop is one of
// the three outcomes read_line has: a line, the end of input (none), or
// a read error.
let n = 0;
while true {
    let r = io.read_line();
    guard let maybe = r else let e = err_of(r) { die("read_line: " + e); }
    guard let line = maybe else { break; }
    n = n + 1;
    if len(line) > 100 {
        println("line " + to_str(n) + ": " + to_str(len(line)) + " bytes");
    } else {
        println("line " + to_str(n) + ": [" + line + "] len " + to_str(len(line)));
    }
}
println("lines: " + to_str(n));

// The end of input is not an error, and asking again is still not one.
let again = io.read_line();
guard let m2 = again else let e2 = err_of(again) { die("second EOF read: " + e2); }
if (m2 ?? "<none>") != "<none>" { die("a read after EOF returned data"); }

// Nothing is left for read_all either.
let rest = io.read_all();
guard let b = rest else let e3 = err_of(rest) { die("read_all after EOF: " + e3); }
if len(b) != 0 { die("read_all after EOF returned bytes"); }

// stdin here is a file and stdout a pipe or file: neither is a terminal.
if io.is_tty(0) { die("stdin is a file, is_tty(0) said terminal"); }
if io.is_tty(1) { die("stdout is captured, is_tty(1) said terminal"); }

io.flush();
io.eprint("stderr: no newline, ");
io.eprintln("then one");
println("io ok");
