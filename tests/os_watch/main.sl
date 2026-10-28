import "os";
import "fs";
import "time";

fn writer(path: str) {
    time.sleep(80000000); // 80ms
    let cr = fs.create(path);
    guard let fd = cr else { return; }
    let _w = fs.write(fd, b"watcher payload");
    let _c = fs.close(fd);
}

let tmp = os.tmpdir() + "/slang_test_os_watch";
let _r = os.remove(tmp);
let _m = fs.mkdir(tmp);

let mt = os.mtime_ns(tmp);
guard let ns = mt else {
    println("FAIL: mtime_ns failed");
    exit(1);
}
if ns < 1577836800000000000 {
    println("FAIL: mtime_ns too small");
    exit(1);
}
println("mtime_ns ok");

let excludes: [str] = [".git", "ignored"];
let wr = os.watch(tmp, excludes);
guard let handle = wr else {
    println("FAIL: watch failed");
    exit(1);
}
if handle <= 0 {
    println("FAIL: handle not positive");
    exit(1);
}
println("watch start ok");

// 1. Timeout test: 40ms in future
let t0 = os.watch_next(handle, until_of(time.mono() + 40000000));
guard let _events0 = t0 else let e0 = err_of(t0) {
    if e0 != "timeout" {
        println("FAIL: expected timeout, got: " + e0);
        exit(1);
    }
    println("watch_next timeout ok");

    // 2. Event notification test: 2s in future
    let file = tmp + "/test.txt";
    spawn writer(file);

    let t1 = os.watch_next(handle, until_of(time.mono() + 2000000000));
    guard let events = t1 else let e1 = err_of(t1) {
        println("FAIL: watch_next failed: " + e1);
        exit(1);
    }
    let saw_test = false;
    for i in 0..len(events) {
        if events[i] == "test.txt" {
            saw_test = true;
        }
    }
    if !saw_test {
        println("FAIL: did not see test.txt in events");
        exit(1);
    }
    println("watch_next event received ok");

    let cr = os.watch_close(handle);
    guard let _ok = cr else {
        println("FAIL: watch_close failed");
        exit(1);
    }
    println("watch_close ok");

    let _rf = os.remove(file);
    let _rd = os.remove(tmp);
    println("os_watch tests passed");
    exit(0);
}
println("FAIL: expected timeout");
exit(1);
