// Raw mode left on at exit: atexit puts the terminal back.
import "io";

let r = io.raw_on();
guard let ok = r else let e = err_of(r) { println("ERR " + e); exit(1); }
println("ready");
exit(0);
