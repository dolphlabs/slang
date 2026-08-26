// proc: process lifecycle -- shutdown_requested()/active_tasks() are
// exercised more fully (real signal, real listener, real drain) in
// tests/proc_shutdown; this covers the basics deterministically.
import "proc";
import "time";

fn slow_task() {
    time.sleep(150000000);
}

println(to_str(proc.shutdown_requested()));
println(to_str(proc.active_tasks()));

spawn slow_task();
time.sleep(20000000); // let it actually start
println(to_str(proc.active_tasks()));
time.sleep(300000000); // long enough to finish
println(to_str(proc.active_tasks()));

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
