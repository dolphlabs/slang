// A spawned process inherits none of the program's sockets or files:
// listeners, accepted and dialed connections, Unix sockets and fs fds are
// all close-on-exec. Before, a child held every one open -- a listener's
// port stayed bound and a peer saw no close until the child exited.
import "fs";
import "net";
import "os";
import "proc";
import "strings";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn run() {
    let l = net.listen(0) ?? (-1 as i32);
    let port = net.port(l) ?? 0;
    let c = net.dial("127.0.0.1", port) ?? (-1 as i32);
    let s = net.accept(l) ?? (-1 as i32);
    let upath = "/tmp/sl_spawn_no_fd_leak.sock";
    let _rm = os.remove(upath);
    let ul = net.listen_unix(upath) ?? (-1 as i32);
    let f = fs.open("tests/proc_spawn_no_fd_leak/main.sl") ?? (-1 as i32);
    let fds = [l, c, s, ul, f];
    for fd in fds {
        if fd < 0 { die("setup"); }
    }
    let list = "";
    for fd in fds {
        list = list + " " + to_str(fd);
    }
    // Is fd N open in the child? `[ -e /dev/fd/N ]` asks the shell's own
    // fd table (test is a builtin, so no other process or fd is involved).
    // Not `true >&N`: dash, Ubuntu's sh, takes only one-digit fds in a
    // redirection, and on Linux the program's sockets are past 9.
    // Each line is appended by its own command, so no redirection is in
    // force while the probe runs: dash keeps stdout on a spare fd of 10 or
    // more while a `{ ...; } > file` group runs, and that spare can be one
    // of the numbers probed.
    let outp = "/tmp/sl_spawn_no_fd_leak.out";
    let script = ": > " + outp + "; for fd in" + list + "; do if [ -e /dev/fd/$fd ]; then echo leaked >> " + outp + "; fi; done; echo checked >> " + outp;
    let noenv: [str] = [];
    let r = proc.spawn(["sh", "-c", script], noenv, "", 0);
    guard let pid = r else let e = err_of(r) { die("spawn: " + e); }
    let _w = proc.wait(pid, until_never());
    let ofd = fs.open("/tmp/sl_spawn_no_fd_leak.out") ?? (-1 as i32);
    let out = to_str(fs.read(ofd, 4096) ?? b"");
    fs.close(ofd);
    if !strings.contains(out, "checked") { die("child did not run: " + out); }
    if strings.contains(out, "leaked") { die("child inherited " + to_str(strings.count(out, "leaked")) + " of the program's fds"); }
    println("child inherited none of 5 fds");
    for fd in fds {
        if fd == f { fs.close(fd); } else { net.close(fd); }
    }
    let _rm2 = os.remove(upath);
}

run();
