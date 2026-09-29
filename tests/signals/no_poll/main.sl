// Imports proc for something other than shutdown, and never asks
// proc.shutdown_requested(): SIGINT/SIGTERM must keep their default
// action. Importing proc used to make them a flag nobody read, so this
// program could only be stopped with SIGKILL. Driven by run_tests.sh.
import "io";
import "proc";
import "time";

let name = proc.getenv("SL_SIGNAL_TEST") ?? "no_poll";
println("ready " + name);
io.flush(); // stdout to a file is buffered; the runner waits for this line
while true {
    time.sleep(10000000);
}
