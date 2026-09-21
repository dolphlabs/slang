import "io";

// io.read_key decodes the bytes of a key press into a name. The bytes come
// from tests/io_keys/stdin.txt, a regular file: the decoder does not care
// whether it is a terminal (tests/io_tty covers the terminal, including
// the timing that tells a lone Escape from the start of a sequence).

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

let n = 0;
while true {
    let r = io.read_key();
    guard let maybe = r else let e = err_of(r) { die("read_key: " + e); }
    guard let key = maybe else { break; }
    println("key " + key);
    n = n + 1;
}
println("keys: " + to_str(n));

// The end of input is not an error, and asking again is still not one.
let again = io.read_key();
guard let m2 = again else let e2 = err_of(again) { die("second EOF read: " + e2); }
if (m2 ?? "<none>") != "<none>" { die("a key after the end of input"); }
