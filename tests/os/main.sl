// os: the operating system around a program.
//
// The fs/os split under test here: `fs` owns open file HANDLES and
// their contents, `os` owns everything you can ask or do about a path
// WITHOUT opening it, plus the environment and the process. So this
// uses fs to CREATE a file and os to ask about it -- which is also the
// shape a real static-file server has.

import "os";
import "fs";
import "proc";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn scratch() -> str {
    return os.tmpdir() + "/slang_os_test";
}

fn setup() -> str {
    let dir = scratch();
    // Left over from a previous run? Clear it, which also exercises
    // remove() on both a file and a directory.
    let rd = os.read_dir(dir);
    guard let names = rd else {
        // not there at all; nothing to clean
        let mk = fs.mkdir(dir);
        guard let _m = mk else let e = err_of(mk) { die("mkdir: " + e); }
        return dir;
    }
    for i in 0..len(names) {
        let rr = os.remove(dir + "/" + names[i]);
        guard let _x = rr else let e = err_of(rr) { die("cleanup: " + e); }
    }
    return dir;
}

fn write_file(path: str, body: bytes) {
    let cr = fs.create(path);
    guard let fd = cr else let e = err_of(cr) { die("create: " + e); }
    let wr = fs.write(fd, body);
    guard let _n = wr else let e = err_of(wr) { die("write: " + e); }
    let cl = fs.close(fd);
    guard let _c = cl else let e = err_of(cl) { die("close: " + e); }
}

fn run() {
    let dir = setup();

    // ---- environment -------------------------------------------------
    let sr = os.setenv("SLANG_OS_TEST", "hello");
    guard let _s = sr else let e = err_of(sr) { die("setenv: " + e); }
    let got = proc.getenv("SLANG_OS_TEST") ?? "";
    if got != "hello" { die("setenv did not take: " + got); }
    println("setenv/getenv round-trip");

    // environ must contain what we just set, in KEY=VALUE form.
    let env = os.environ();
    let found = false;
    for i in 0..len(env) {
        if env[i] == "SLANG_OS_TEST=hello" {
            found = true;
        }
    }
    if !found { die("environ did not list the new variable"); }
    if len(env) < 2 { die("environ looks empty"); }
    println("environ lists it");

    let ur = os.unsetenv("SLANG_OS_TEST");
    guard let _u = ur else let e = err_of(ur) { die("unsetenv: " + e); }
    let after: opt[str] = proc.getenv("SLANG_OS_TEST");
    guard let leftover = after else {
        println("unsetenv removed it");
        // A name containing '=' is not a variable name; it must be
        // rejected rather than passed to libc.
        let br = os.setenv("BAD=NAME", "x");
        guard let _b = br else {
            println("rejected a name containing '='");
            run2(dir);
            return;
        }
        die("setenv accepted a name containing '='");
    }
    die("unsetenv left it behind: " + leftover);
}

fn run2(dir: str) {
    // ---- path metadata -----------------------------------------------
    let f = dir + "/hello.txt";
    write_file(f, b"0123456789");

    if !os.exists(f) { die("exists() says a file we just wrote is missing"); }
    if !os.is_file(f) { die("is_file() on a regular file"); }
    if os.is_dir(f) { die("is_dir() true for a regular file"); }
    if !os.is_dir(dir) { die("is_dir() on a directory"); }
    // A directory is not something you can read as a file.
    if os.is_file(dir) { die("is_file() true for a directory"); }
    if os.exists(dir + "/nope") { die("exists() true for a missing path"); }
    println("metadata predicates agree");

    let szr = os.size(f);
    guard let sz = szr else let e = err_of(szr) { die("size: " + e); }
    if sz != 10 { die("size says ${sz}, wrote 10"); }
    println("size is exact");

    let mr = os.mtime(f);
    guard let mt = mr else let e = err_of(mr) { die("mtime: " + e); }
    // Sanity, not precision: after 2020 and before 2100.
    if mt < 1577836800 { die("mtime is implausibly old: ${mt}"); }
    if mt > 4102444800 { die("mtime is implausibly far ahead: ${mt}"); }
    println("mtime is plausible");

    // The accessors must report WHY, not just fail.
    let bad = os.size(dir + "/definitely-not-here");
    guard let _bs = bad else let e = err_of(bad) {
        if len(e) < 5 { die("size error is too terse: " + e); }
        println("size on a missing path explains itself");
        run3(dir, f);
            return;
    }
    die("size succeeded on a missing path");
}

fn run3(dir: str, f: str) {
    // ---- directories -------------------------------------------------
    write_file(dir + "/second.txt", b"xx");

    let dr = os.read_dir(dir);
    guard let names = dr else let e = err_of(dr) { die("read_dir: " + e); }
    if len(names) != 2 { die("read_dir found ${len(names)} entries, wrote 2"); }
    // "." and ".." must not be there -- forgetting to filter them is
    // how a directory walk becomes an infinite loop.
    for i in 0..len(names) {
        if names[i] == "." || names[i] == ".." {
            die("read_dir returned " + names[i]);
        }
    }
    let saw_hello = false;
    let saw_second = false;
    for i in 0..len(names) {
        if names[i] == "hello.txt" { saw_hello = true; }
        if names[i] == "second.txt" { saw_second = true; }
    }
    if !saw_hello || !saw_second { die("read_dir missed an entry"); }
    println("read_dir lists entries, without . and ..");

    let nd = os.read_dir(dir + "/not-a-dir");
    guard let _n = nd else {
        println("read_dir on a missing directory errors");
        run4(dir, f);
            return;
    }
    die("read_dir succeeded on a missing directory");
}

fn run4(dir: str, f: str) {
    // ---- namespace ---------------------------------------------------
    let moved = dir + "/renamed.txt";
    let rr = os.rename(f, moved);
    guard let _r = rr else let e = err_of(rr) { die("rename: " + e); }
    if os.exists(f) { die("rename left the original behind"); }
    if !os.exists(moved) { die("rename did not produce the target"); }
    println("rename moves the file");

    let xr = os.remove(moved);
    guard let _x = xr else let e = err_of(xr) { die("remove: " + e); }
    if os.exists(moved) { die("remove left the file behind"); }
    println("remove deletes a file");

    let x2 = os.remove(dir + "/second.txt");
    guard let _y = x2 else let e = err_of(x2) { die("remove 2: " + e); }

    // remove() takes empty directories too, so a caller need not know
    // which kind of thing it has.
    let dx = os.remove(dir);
    guard let _d = dx else let e = err_of(dx) { die("remove dir: " + e); }
    if os.exists(dir) { die("remove left the directory behind"); }
    println("remove deletes an empty directory");

    let gone = os.remove(dir + "/never-existed");
    guard let _g = gone else {
        println("remove on a missing path errors");
        println("os ok");
        return;
    }
    die("remove succeeded on a missing path");
}

run();
