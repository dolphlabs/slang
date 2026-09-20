// The prompt must be visible BEFORE the person types. print() leaves it
// in stdout's buffer; io.read_line flushes it before it waits.
import "io";

print("name? ");
let r = io.read_line();
guard let maybe = r else let e = err_of(r) { println("ERR: " + e); exit(1); }
guard let name = maybe else { exit(0); }
println("hello, " + name);
