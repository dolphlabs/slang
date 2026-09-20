// A tiny REPL: Ctrl-D ends one read but is not sticky (as in a shell),
// and with proc imported Ctrl-C surfaces as an ordinary error instead of
// killing the process, so the program can clean up.
import "io";
import "proc";

let eofs = 0;
while eofs < 2 {
    print("> ");
    let r = io.read_line();
    guard let maybe = r else let e = err_of(r) {
        println("ERR: " + e);
        exit(3);
    }
    guard let line = maybe else {
        println("<eof>");
        eofs = eofs + 1;
        continue;
    }
    println("got: " + line);
}
println("bye");
