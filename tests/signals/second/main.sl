// Asks proc.shutdown_requested(), so the first SIGTERM is a graceful
// request -- and then never finishes draining. The second SIGTERM must
// end the process anyway. Driven by run_tests.sh.
import "io";
import "proc";
import "time";

println("ready");
io.flush(); // stdout to a file is buffered; the runner waits for this line
while !proc.shutdown_requested() {
    time.sleep(10000000);
}
println("shutdown requested");
io.flush(); // stdout to a file is buffered; the runner waits for this line
while true {
    time.sleep(10000000);
}
