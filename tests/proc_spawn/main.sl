import "proc";
import "time";

let env: [str] = [];

// 1. spawn a simple command that prints and exits 0
let res = proc.spawn(["/bin/echo", "proc_spawn_ok"], env, "", 0);
guard let pid = res else {
    println("FAIL: spawn failed");
    exit(1);
}
if pid <= 0 {
    println("FAIL: pid not positive");
    exit(1);
}

let wait_res = proc.wait(pid, until_never());
guard let code = wait_res else {
    println("FAIL: wait failed");
    exit(1);
}
if code != 0 {
    println("FAIL: exit code was ${code}");
    exit(1);
}
println("exit code 0 ok");

// 2. spawn a command that exits with code 42, using SPAWN_NULL_STDIN
let res2 = proc.spawn(["/bin/sh", "-c", "exit 42"], env, "", proc.SPAWN_NULL_STDIN);
guard let pid2 = res2 else {
    println("FAIL: spawn 2 failed");
    exit(1);
}
let wait_res2 = proc.wait(pid2, until_never());
guard let code2 = wait_res2 else {
    println("FAIL: wait 2 failed");
    exit(1);
}
if code2 != 42 {
    println("FAIL: exit code 2 was ${code2}");
    exit(1);
}
println("exit code 42 ok");

// 3. spawn with SPAWN_GROUP, test timeout and kill
let res3 = proc.spawn(["/bin/sleep", "5"], env, "", proc.SPAWN_GROUP);
guard let pid3 = res3 else {
    println("FAIL: spawn 3 failed");
    exit(1);
}

// Deadline 50ms in future
let t0 = proc.wait(pid3, until_of(time.mono() + 50000000));
guard let _c3 = t0 else let e = err_of(t0) {
    if e != "timeout" {
        println("FAIL: unexpected wait err: " + e);
        exit(1);
    }
    println("wait timeout ok");

    let kr = proc.kill(-pid3, 9);
    guard let _k = kr else {
        println("FAIL: kill failed");
        exit(1);
    }

    let wait_res3 = proc.wait(pid3, until_never());
    guard let code3 = wait_res3 else {
        println("FAIL: wait 3 failed");
        exit(1);
    }
    // Process killed by SIGKILL (9) -> 128 + 9 = 137 or 9
    if code3 != 137 && code3 != 9 {
        println("FAIL: unexpected kill status ${code3}");
        exit(1);
    }
    println("kill signal ok");
    println("proc_spawn tests passed");
    exit(0);
}
println("FAIL: expected wait timeout");
exit(1);
