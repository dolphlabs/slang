// Raw mode in a program that handles shutdown but ignores the first
// Ctrl-C and keeps reading keys. The second Ctrl-C must still end it --
// and put the terminal back first, since that signal is raised on proc's
// signal thread and reaches io's restore hook there.
import "io";
import "proc";

let r = io.raw_on();
guard let ok = r else let e = err_of(r) { println("ERR " + e); exit(1); }
println("raw");
while true {
    let k = io.read_key();
    guard let _key = k else {
        if proc.shutdown_requested() {
            println("interrupted once");
        }
        continue;
    }
}
