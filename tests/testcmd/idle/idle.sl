// Fixture for run_tests.sh: a test that waits for the tasks it spawned.
// `slangc test` runs each test in a spawned task, and proc.wait_idle()
// used to count that task, so this test never returned.
import "proc";

pub fn bump(c: chan[int]) {
    chan_send(c, 1);
}
