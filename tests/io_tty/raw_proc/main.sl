// Raw mode in a program that handles shutdown (it calls
// proc.shutdown_requested()): Ctrl-C is an "interrupted" error from the
// read, not a kill, and the terminal is put back on the way out.
import "io";
import "proc";

let r = io.raw_on();
guard let ok = r else let e = err_of(r) { println("ERR " + e); exit(1); }
println("raw");
let k = io.read_key();
guard let maybe = k else let e2 = err_of(k) {
    if !proc.shutdown_requested() {
        println("ERR (not a shutdown request) " + e2);
        exit(4);
    }
    println("ERR " + e2);
    exit(3);
}
println("key " + (maybe ?? "<eof>"));
