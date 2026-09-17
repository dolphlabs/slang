// proc: process lifecycle -- shutdown_requested()/active_tasks() are
// exercised more fully (real signal, real listener, real drain) in
// tests/proc_shutdown; this covers the basics deterministically.
//
// Deterministically for real now. This used to spawn a task that slept
// 150ms, sleep 20ms itself, and expect the task still running. On
// GitHub's macOS runners a 20ms sleep was measured taking up to 167ms --
// and plain C nanosleep up to 126ms on the same machine, so the timer
// overshoot is the virtualised runner's, not slang's -- and the test
// failed about one run in five. The task now waits on a channel, so it is
// still running when counted because nothing has released it, not because
// a race was won.
import "proc";

fn held_task(gate: chan[bool]) {
    let _released = chan_recv(gate);
}

println(to_str(proc.shutdown_requested()));
println(to_str(proc.active_tasks()));

let gate: chan[bool] = make_chan(1);
spawn held_task(gate);
println(to_str(proc.active_tasks()));   // counted from the spawn, held open by the gate
chan_send(gate, true);
proc.wait_idle();
println(to_str(proc.active_tasks()));

let argv = proc.args();
println(len(argv) >= 1);
println(len(argv[0]) > 0);

let cr = proc.cwd();
guard let cwd = cr else {
    println("FAIL: cwd");
    exit(1);
}
println(to_str(len(cwd) > 0));
println(to_str(to_bytes(cwd)[0] == 47));

let r: opt[str] = proc.getenv("PATH");
guard let path = r else {
    println("FAIL: PATH should be set in any normal environment");
    exit(1);
}
println(to_str(len(path) > 0));

let missing: opt[str] = proc.getenv("SLANG_TEST_ENV_VAR_DOES_NOT_EXIST");
guard let _v = missing else {
    println("missing env var correctly none");
    exit(0);
}
println("FAIL: expected none for an unset env var");
exit(1);
