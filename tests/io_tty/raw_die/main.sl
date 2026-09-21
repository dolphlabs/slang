// Raw mode, no proc: Ctrl-C keeps working (raw mode leaves signals on) and
// kills the process -- which must put the terminal back first.
import "io";

let r = io.raw_on();
guard let ok = r else let e = err_of(r) { println("ERR " + e); exit(1); }
println("raw");
while true {
    let k = io.read_key();
    guard let maybe = k else let e2 = err_of(k) { println("ERR " + e2); exit(1); }
    println("key " + (maybe ?? "<eof>"));
}
