// A deadline is an absolute instant, not a duration. Passing the
// duration directly would park until 1970 and return instantly, so
// NA_UNTIL refuses an int rather than coercing it.
import "net";

fn run() {
    let r = net.recv_until(0, 64, 5000000);
    guard let d = r else { return; }
    println(len(d));
}

run();
