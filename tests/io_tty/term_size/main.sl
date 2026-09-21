// The terminal's size, asked afresh each time, and none when there is no
// terminal. Prints after every line, and once more at end of input.
import "io";

while true {
    println("size " + to_str(io.term_width() ?? -1) + "x" + to_str(io.term_height() ?? -1));
    let r = io.read_line();
    guard let maybe = r else let e = err_of(r) { println("ERR " + e); exit(1); }
    guard let line = maybe else { break; }
}
